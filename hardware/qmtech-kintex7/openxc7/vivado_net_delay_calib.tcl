# TASK 1: ground nextpnr's predictDelay against Vivado's real routed net delays.
#
# WHY THIS IS FIRST
# -----------------
# The 65.19 MHz figure that reframed this investigation is NOT a routed
# measurement. Context::getNetinfoRouteDelay falls back to Arch::predictDelay
# whenever net->wires is empty, and router2 never binds wires during the search,
# so it is ALWAYS empty. The reported "11.0 ns" for the critical net is exactly
# predictDelay(dx=107, dy=268):
#
#     30*18 + 10*89 + 60*6 + 20*262 + 300 = 7330 ps,  x1.5 (xc7) = 10.995 ns
#
# to three significant figures. nextpnr never measured that path.
#
# The formula uses 30 ps/tile in x and 60 in y (45/90 after the xc7 x1.5).
# prjxray's own kintex7 INT_L pip delays say the fabric is not anisotropic that
# way -- LONG 198 ps, QUAD/HEX 119, DOUBLE 90, LOCAL 69, i.e. ~16.5/30/45 ps per
# tile spanned in BOTH directions. If the y coefficient is wrong then with
# NEXTPNR_ISO_HEURISTIC the same unmoved placement reports 6.795 ns instead of
# 10.995 -- 13.1 ns -> 8.9 ns, ~112 MHz, zero cells moved.
#
# So: is 65 MHz real, or an artefact of the y coefficient?
#
# WHAT THIS DOES
# --------------
# For a sample of routed nets, records source->sink distance in tile coordinates
# alongside the delay Vivado actually measured, so the 30/10/60/20/300 formula can
# be checked PER AXIS -- which is the whole question.
#
# Uses get_net_delays (delay objects on a routed design) rather than timing-path
# properties: an earlier version used get_property NETS/NET_DELAYS on timing
# paths and silently produced zero rows.
#
# Run:  vivado -mode batch -source vivado_net_delay_calib.tcl
# Out:  vivado_net_delay_calib.csv   dx,dy,manhattan,delay_ns,fanout,net

set dcp ../vivado/build/am01_qmtech_kintex7.runs/impl_1/am01_qmtech_top_routed.dcp
set out vivado_net_delay_calib.csv
set want 3000

if {![file exists $dcp]} { puts "ERROR: no checkpoint at $dcp"; exit 1 }
open_checkpoint $dcp
puts "part [get_property PART [current_design]]"

# Discovery: report what a delay object actually exposes, so a property-name
# mismatch fails loudly here instead of silently emitting nothing.
set probe [get_nets -quiet -hierarchical -filter {ROUTE_STATUS == ROUTED} -top_net_of_hierarchical_group]
puts "candidate nets: [llength $probe]"
if {[llength $probe] > 0} {
    set pn [lindex $probe 0]
    set pd [get_net_delays -quiet -of_objects $pn]
    puts "sample net    : $pn"
    puts "delay objects : [llength $pd]"
    if {[llength $pd] > 0} {
        puts "delay props   : [list_property [lindex $pd 0]]"
    }
}

set fh [open $out w]
puts $fh "dx,dy,manhattan,delay_ns,fanout,net"

# Iterate the delay OBJECTS and read TO_PIN off each, rather than filtering
# get_net_delays with -to: the previous version did the latter and produced zero
# rows even though the probe showed a valid delay object on the same net.
# -leaf on the driver lookup matters too -- these are hierarchical net names.
set n 0
set skipped 0
foreach net $probe {
    if {$n >= $want} { break }

    set drv [get_pins -quiet -leaf -of_objects $net -filter {DIRECTION == OUT}]
    if {[llength $drv] == 0} { incr skipped; continue }
    set dsite [get_sites -quiet -of_objects [lindex $drv 0]]
    if {$dsite eq ""} { incr skipped; continue }
    set dtile [get_tiles -quiet -of_objects $dsite]
    if {$dtile eq ""} { incr skipped; continue }
    set dcol [get_property -quiet COLUMN $dtile]
    set drow [get_property -quiet ROW $dtile]
    if {$dcol eq "" || $drow eq ""} { incr skipped; continue }

    set dlys [get_net_delays -quiet -of_objects $net]
    if {[llength $dlys] == 0} { incr skipped; continue }

    foreach dly $dlys {
        if {$n >= $want} { break }
        set d [get_property -quiet SLOW_MAX $dly]
        if {$d eq "" || $d <= 0} { continue }
        set topin [get_property -quiet TO_PIN $dly]
        if {$topin eq ""} { continue }
        set lsite [get_sites -quiet -of_objects [get_pins -quiet $topin]]
        if {$lsite eq ""} { continue }
        set ltile [get_tiles -quiet -of_objects $lsite]
        if {$ltile eq ""} { continue }
        set lcol [get_property -quiet COLUMN $ltile]
        set lrow [get_property -quiet ROW $ltile]
        if {$lcol eq "" || $lrow eq ""} { continue }

        set dx [expr {abs($dcol - $lcol)}]
        set dy [expr {abs($drow - $lrow)}]
        puts $fh "$dx,$dy,[expr {$dx + $dy}],$d,[llength $dlys],$net"
        incr n
    }
}
close $fh
puts "wrote $n samples to $out (skipped $skipped nets)"
