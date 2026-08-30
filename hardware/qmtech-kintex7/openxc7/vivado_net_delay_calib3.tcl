# Calibrate nextpnr's predictDelay against Vivado's routed net delays.
#
# HISTORY OF FAILURES (both produced header-only CSVs):
#   v1 vivado_net_delay_calib.tcl  -- pointed at a DCP that does not exist.
#   v2 vivado_net_delay_calib2.tcl -- reached the design but dropped every net:
#        "WROTE 0 rows from 0 nets (no_drv 9, no_dly 7047, no_loc 76581)"
#      i.e. get_tiles -of_objects <site> / COLUMN / ROW yielded nothing for
#      76581 of 83637 nets. That idiom does not work in Vivado 2026.1.
#
# So this version does two things at once:
#   (a) DIAGNOSTIC: dump list_property for a site and a tile object, once, so
#       the correct property names are recorded for good.
#   (b) DATA: derive coordinates by regexp on the SITE NAME (SLICE_X5Y137 ->
#       5,137), which cannot fail, and ALSO record tile COLUMN/ROW when they
#       happen to resolve. Site-name X/Y is a different pitch from nextpnr's
#       tile grid, so rows carry the site-type prefix and analysis is
#       restricted to SLICE->SLICE pairs for a uniform coordinate system.
#
# Out: vivado_net_delay_calib3.csv
#      sx,sy,dxs,dys,manhattan,delay_ns,fanout,dtype,ltype,col_ok

set dcp vivado_routed_nextpnr_placement.dcp
set out vivado_net_delay_calib3.csv
set want 6000

if {![file exists $dcp]} { puts "ERROR: no checkpoint at $dcp"; exit 1 }
open_checkpoint $dcp
puts "PART [get_property PART [current_design]]"

set allnets [get_nets -quiet -hierarchical -filter {TYPE == SIGNAL}]
puts "CANDIDATE_NETS [llength $allnets]"

# ---------- diagnostic: what do these objects actually expose? ----------
set diag_done 0
proc diagnose {pin} {
    set site [get_sites -quiet -of_objects $pin]
    puts "DIAG pin  : $pin"
    puts "DIAG site : $site"
    if {$site ne ""} {
        puts "DIAG site props: [list_property $site]"
        set t [get_tiles -quiet -of_objects $site]
        puts "DIAG tile : '$t'"
        if {$t ne ""} { puts "DIAG tile props: [list_property $t]" }
    }
}

# Parse trailing X<n>Y<n> off a site name. Returns {ok x y type}.
proc sitexy {sname} {
    if {[regexp {^(.*)_X(\d+)Y(\d+)$} $sname -> pre x y]} {
        return [list 1 $x $y $pre]
    }
    return [list 0 0 0 ""]
}

set fh [open $out w]
puts $fh "sx,sy,dxs,dys,manhattan,delay_ns,fanout,dtype,ltype,col_ok"

set n 0
set no_drv 0 ; set no_dly 0 ; set no_site 0 ; set no_xy 0
set nets_used 0

foreach net $allnets {
    if {$n >= $want} { break }

    set dlys [get_net_delays -quiet -of_objects $net]
    if {[llength $dlys] == 0} { incr no_dly ; continue }

    set drv [get_pins -quiet -leaf -of_objects $net -filter {DIRECTION == OUT}]
    if {[llength $drv] == 0} { incr no_drv ; continue }

    if {!$diag_done} { diagnose [lindex $drv 0] ; set diag_done 1 }

    set dsite [get_sites -quiet -of_objects [lindex $drv 0]]
    if {$dsite eq ""} { incr no_site ; continue }
    lassign [sitexy "$dsite"] ok dsx dsy dtype
    if {!$ok} { incr no_xy ; continue }

    # tile column/row if they resolve at all -- recorded as a flag only
    set col_ok 0
    set dtile [get_tiles -quiet -of_objects $dsite]
    if {$dtile ne ""} {
        set c [get_property -quiet COLUMN $dtile]
        if {$c ne ""} { set col_ok 1 }
    }

    set used 0
    foreach dly $dlys {
        if {$n >= $want} { break }
        set d [get_property -quiet SLOW_MAX $dly]
        if {$d eq "" || $d <= 0} { continue }
        set topin [get_property -quiet TO_PIN $dly]
        if {$topin eq ""} { continue }
        set lsite [get_sites -quiet -of_objects [get_pins -quiet $topin]]
        if {$lsite eq ""} { continue }
        lassign [sitexy "$lsite"] lok lsx lsy ltype
        if {!$lok} { continue }
        set dxs [expr {abs($dsx - $lsx)}]
        set dys [expr {abs($dsy - $lsy)}]
        puts $fh "$dsx,$dsy,$dxs,$dys,[expr {$dxs + $dys}],$d,[llength $dlys],$dtype,$ltype,$col_ok"
        incr n
        set used 1
    }
    if {$used} { incr nets_used }
    if {$n % 1000 == 0 && $n > 0} { puts "PROGRESS $n" ; flush $fh }
}
close $fh
puts "WROTE $n rows from $nets_used nets (no_drv $no_drv, no_dly $no_dly, no_site $no_site, no_xy $no_xy)"
exit 0
