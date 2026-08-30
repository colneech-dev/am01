# Calibrate nextpnr's predictDelay against Vivado's routed net delays, on the
# nextpnr placement (vivado_routed_nextpnr_placement.dcp).
#
# WHY v1-v3 ALL PRODUCED HEADER-ONLY CSVs
# ---------------------------------------
#   v1  pointed at ../vivado/build/.../am01_qmtech_top_routed.dcp -- absent.
#   v2  "WROTE 0 rows (no_drv 9, no_dly 7047, no_loc 76581)".
#   v3  diagnostic pinned it exactly:
#         DIAG pin  : $abc$490857$auto$blifparse.cc:557:parse_blif$499618/O
#         DIAG site :                                    <-- EMPTY
#       get_sites -of_objects does NOT traverse from a CELL PIN. That is the
#       whole bug; it has nothing to do with the '$'/':' in yosys names.
#
# THE FIX
# -------
# Use the idiom this project's own vivado_place_export_norename.tcl:131-138
# already proved works: iterate get_cells and read LOC off the loop variable.
# Build cellname -> site once, then resolve pins by pure string manipulation
# (strip the last '/'), so no object is ever re-resolved from a name.
#
# Out: vivado_net_delay_calib4.csv
#      dsx,dsy,lsx,lsy,dxs,dys,manhattan,delay_ns,fanout,dtype,ltype

set dcp vivado_routed_nextpnr_placement.dcp
set out vivado_net_delay_calib4.csv
set want 8000

if {![file exists $dcp]} { puts "ERROR: no checkpoint at $dcp"; exit 1 }
open_checkpoint $dcp
puts "PART [get_property PART [current_design]]"

# ---------- pass 1: cell name -> site name ----------
puts "== building cell -> site map =="
array set CELLSITE {}
set nmapped 0
foreach c [get_cells -hierarchical -filter {IS_PRIMITIVE}] {
    set loc [get_property -quiet LOC $c]
    if {$loc eq ""} { continue }
    set CELLSITE([get_property NAME $c]) $loc
    incr nmapped
}
puts "MAPPED $nmapped placed cells"

# ---------- diagnostic: what does a net-delay object expose? ----------
set probe [lindex [get_nets -quiet -hierarchical -filter {TYPE == SIGNAL}] 0]
set pdl [get_net_delays -quiet -of_objects $probe]
puts "DIAG net          : $probe"
puts "DIAG delay objects: [llength $pdl]"
if {[llength $pdl] > 0} {
    puts "DIAG delay props  : [list_property [lindex $pdl 0]]"
}

# Parse trailing X<n>Y<n> off a site name -> {ok x y type}
proc sitexy {sname} {
    if {[regexp {^(.*)_X(\d+)Y(\d+)$} $sname -> pre x y]} { return [list 1 $x $y $pre] }
    return [list 0 0 0 ""]
}
# Cell name for a pin name: everything before the LAST '/'
proc pincell {p} {
    set i [string last "/" $p]
    if {$i < 0} { return "" }
    return [string range $p 0 [expr {$i - 1}]]
}

set allnets [get_nets -quiet -hierarchical -filter {TYPE == SIGNAL}]
puts "CANDIDATE_NETS [llength $allnets]"

set fh [open $out w]
puts $fh "dsx,dsy,lsx,lsy,dxs,dys,manhattan,delay_ns,fanout,dtype,ltype"

set n 0
set no_dly 0 ; set no_drv 0 ; set no_dloc 0 ; set no_lloc 0
set nets_used 0

foreach net $allnets {
    if {$n >= $want} { break }

    set dlys [get_net_delays -quiet -of_objects $net]
    if {[llength $dlys] == 0} { incr no_dly ; continue }

    set drv [get_pins -quiet -leaf -of_objects $net -filter {DIRECTION == OUT}]
    if {[llength $drv] == 0} { incr no_drv ; continue }
    set dcell [pincell [lindex $drv 0]]
    if {$dcell eq "" || ![info exists CELLSITE($dcell)]} { incr no_dloc ; continue }
    lassign [sitexy $CELLSITE($dcell)] dok dsx dsy dtype
    if {!$dok} { incr no_dloc ; continue }

    set used 0
    foreach dly $dlys {
        if {$n >= $want} { break }
        set d [get_property -quiet SLOW_MAX $dly]
        if {$d eq "" || $d <= 0} { continue }
        set topin [get_property -quiet TO_PIN $dly]
        if {$topin eq ""} { continue }
        set lcell [pincell $topin]
        if {$lcell eq "" || ![info exists CELLSITE($lcell)]} { incr no_lloc ; continue }
        lassign [sitexy $CELLSITE($lcell)] lok lsx lsy ltype
        if {!$lok} { incr no_lloc ; continue }
        set dxs [expr {abs($dsx - $lsx)}]
        set dys [expr {abs($dsy - $lsy)}]
        puts $fh "$dsx,$dsy,$lsx,$lsy,$dxs,$dys,[expr {$dxs + $dys}],$d,[llength $dlys],$dtype,$ltype"
        incr n
        set used 1
    }
    if {$used} { incr nets_used }
    if {$n % 1000 == 0 && $n > 0} { puts "PROGRESS $n" ; flush $fh }
}
close $fh
puts "WROTE $n rows from $nets_used nets (no_dly $no_dly, no_drv $no_drv, no_dloc $no_dloc, no_lloc $no_lloc)"
exit 0
