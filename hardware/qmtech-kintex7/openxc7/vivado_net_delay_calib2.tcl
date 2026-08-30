# Calibrate nextpnr's predictDelay against Vivado's routed net delays, on the
# EXACT placement under investigation (nextpnr placement, Vivado router).
#
# The original vivado_net_delay_calib.tcl produced a header-only CSV (37 bytes,
# zero data rows): it pointed at ../vivado/build/.../am01_qmtech_top_routed.dcp
# and its -top_net_of_hierarchical_group + ROUTE_STATUS filter yielded nothing.
# This version targets vivado_routed_nextpnr_placement.dcp and is defensive at
# every step, reporting WHY rows are dropped instead of silently emitting none.
#
# Out: vivado_net_delay_calib2.csv  dx,dy,manhattan,delay_ns,fanout,net

set dcp vivado_routed_nextpnr_placement.dcp
set out vivado_net_delay_calib2.csv
set want 4000

if {![file exists $dcp]} { puts "ERROR: no checkpoint at $dcp"; exit 1 }
open_checkpoint $dcp
puts "PART [get_property PART [current_design]]"

# Take signal nets with >0 routed delay objects. No hierarchy filter this time.
set allnets [get_nets -quiet -hierarchical -filter {TYPE == SIGNAL}]
puts "CANDIDATE_NETS [llength $allnets]"

set fh [open $out w]
puts $fh "dx,dy,manhattan,delay_ns,fanout,net"

set n 0
set no_drv 0
set no_dly 0
set no_loc 0
set nets_used 0

foreach net $allnets {
    if {$n >= $want} { break }

    set dlys [get_net_delays -quiet -of_objects $net]
    if {[llength $dlys] == 0} { incr no_dly ; continue }

    set drv [get_pins -quiet -leaf -of_objects $net -filter {DIRECTION == OUT}]
    if {[llength $drv] == 0} { incr no_drv ; continue }
    set dtile [get_tiles -quiet -of_objects [get_sites -quiet -of_objects [lindex $drv 0]]]
    if {$dtile eq ""} { incr no_loc ; continue }
    set dcol [get_property -quiet COLUMN $dtile]
    set drow [get_property -quiet ROW $dtile]
    if {$dcol eq "" || $drow eq ""} { incr no_loc ; continue }

    set used 0
    foreach dly $dlys {
        if {$n >= $want} { break }
        set d [get_property -quiet SLOW_MAX $dly]
        if {$d eq "" || $d <= 0} { continue }
        set topin [get_property -quiet TO_PIN $dly]
        if {$topin eq ""} { continue }
        set ltile [get_tiles -quiet -of_objects [get_sites -quiet -of_objects [get_pins -quiet $topin]]]
        if {$ltile eq ""} { continue }
        set lcol [get_property -quiet COLUMN $ltile]
        set lrow [get_property -quiet ROW $ltile]
        if {$lcol eq "" || $lrow eq ""} { continue }
        set dx [expr {abs($dcol - $lcol)}]
        set dy [expr {abs($drow - $lrow)}]
        puts $fh "$dx,$dy,[expr {$dx + $dy}],$d,[llength $dlys],$net"
        incr n
        set used 1
    }
    if {$used} { incr nets_used }
    if {$n % 500 == 0 && $n > 0} { puts "PROGRESS $n" ; flush $fh }
}
close $fh
puts "WROTE $n rows from $nets_used nets (no_drv $no_drv, no_dly $no_dly, no_loc $no_loc)"
exit 0
