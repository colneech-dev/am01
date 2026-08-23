# Post-route timing from an already-routed checkpoint.
#
# WHY THIS IS SEPARATE
# --------------------
# vivado_route_nextpnr_handplaced.tcl routed successfully (0 unrouted, 0 node
# overlaps) but reported no timing, because it never read the pinout XDC and so
# no clocks were defined -- get_clocks returned an empty list and the report
# loop had nothing to iterate. That was a line dropped in a rewrite; the earlier
# working script had `if {[file exists $pinxdc]} { catch {read_xdc $pinxdc} }`.
#
# Place and route are the expensive part (~40 min) and they already succeeded,
# so re-running them to recover a number would be wasteful. Reading the
# checkpoint and applying the timing constraints costs a couple of minutes.
#
# Run:  vivado -mode batch -source vivado_timing_from_dcp.tcl
# Out:  vivado_route_nextpnr_handplaced.txt   (rewritten, with timing)

set dcp    vivado_routed_nextpnr_placement.dcp
set pinxdc ../xdc/qmtech_xc7k325t_pinout.xdc
set out    vivado_route_nextpnr_handplaced.txt

foreach f [list $dcp $pinxdc] {
    if {![file exists $f]} { puts "ERROR: missing $f"; exit 1 }
}

puts "== opening $dcp =="
if {[catch {open_checkpoint $dcp} err]} { puts "ERROR: open_checkpoint: $err"; exit 1 }

puts "== reading timing constraints from $pinxdc =="
if {[catch {read_xdc $pinxdc} err]} { puts "ERROR: read_xdc: $err"; exit 1 }

set clks [get_clocks]
puts "clocks defined: [llength $clks]"
if {[llength $clks] == 0} {
    puts "ERROR: still no clocks -- the XDC did not define any. Not reporting a"
    puts "       number, because a timing report with no clocks is meaningless."
    exit 1
}

set fh [open $out w]
puts $fh "# Vivado ROUTER on nextpnr PLACEMENT (SRL cells left free)"
puts $fh "# constraints applied: 136575 / 136624, skipped 12 SRL lines"
puts $fh "# LOC-fixed cells after place_design: 68266"
puts $fh "# timing recovered from $dcp"
puts $fh ""

foreach clk $clks {
    set nm  [get_property NAME $clk]
    set per [get_property PERIOD $clk]
    set tp [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 \
              -from [get_clocks $nm] -to [get_clocks $nm]]
    if {[llength $tp] == 0} { puts $fh "  $nm: no intra-clock paths"; continue }
    set s   [get_property SLACK $tp]
    set ach [expr {$per - $s}]
    set line [format "  CLOCK %-34s period %7.3f  WNS %8.3f  -> %.3f ns = %.2f MHz" \
                $nm $per $s $ach [expr {1000.0 / $ach}]]
    puts $fh $line
    puts $line
    set l "      logic [get_property -quiet DATAPATH_LOGIC_DELAY $tp] ns  net [get_property -quiet DATAPATH_NET_DELAY $tp] ns"
    puts $fh $l
    puts $l
}

puts $fh ""
set rs [report_route_status -return_string]
foreach ln [split $rs "\n"] {
    if {[string match "*Unrouted Nets*" $ln] || [string match "*Node Overlaps*" $ln]} {
        puts $fh "  [string trim $ln]"
        puts "  [string trim $ln]"
    }
}
close $fh
puts "wrote $out"
