# Vivado place + Vivado route, on the YOSYS netlist.
#
# Establishes the CEILING for this netlist with the commercial tool end to end.
# Every other cell in the matrix should be judged against this number, not
# against the 162 MHz from Vivado's own synthesis (which is a different netlist
# and NUM_MINERS=2).
#
#   place    route     result
#   nextpnr  nextpnr    92.36 MHz  (0 unrouted, complete)
#   Vivado   -          176.43 MHz post-place estimate, WNS +1.832
#   nextpnr  Vivado     (separate script -- isolates the router)
#   Vivado   Vivado     <-- THIS: the ceiling
#
# Post-place was 176 MHz with logic 2.186 ns + net 3.048 ns, against nextpnr's
# ~2.1 ns logic + ~6.9 ns net. Identical logic delay, 2.3x the net delay -- so
# the netlist is not the limit and the gap is placement/routing. Routing will
# degrade the 176; this measures by how much.
#
# Reuses vivado_placed_yosys.dcp so the expensive placement is not repeated.
#
# Run:  vivado -mode batch -source vivado_route_own_placement.tcl
# Out:  vivado_full_flow.txt

set dcp vivado_placed_yosys.dcp
set out vivado_full_flow.txt

if {![file exists $dcp]} {
    puts "ERROR: no placed checkpoint at $dcp -- run vivado_place_export.tcl first"
    exit 1
}

puts "== opening placed checkpoint =="
open_checkpoint $dcp

puts "== routing =="
if {[catch {route_design} err]} { puts "ERROR: route_design: $err"; exit 1 }

write_checkpoint -force vivado_routed_yosys.dcp

puts "== post-route timing =="
set fh [open $out w]
puts $fh "# Vivado place + Vivado route, on the yosys netlist (NUM_MINERS=1)"
foreach clk [get_clocks] {
    set nm [get_property NAME $clk]
    set per [get_property PERIOD $clk]
    set tp [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 \
              -from [get_clocks $nm] -to [get_clocks $nm]]
    if {[llength $tp] == 0} { puts $fh "  $nm: no intra-clock paths"; continue }
    set s [get_property SLACK $tp]
    set ach [expr {$per - $s}]
    set line [format "  CLOCK %-34s period %7.3f  WNS %8.3f  -> %.3f ns = %.2f MHz" \
                $nm $per $s $ach [expr {1000.0 / $ach}]]
    puts $fh $line
    puts $line
    set l "      logic [get_property -quiet DATAPATH_LOGIC_DELAY $tp] ns  net [get_property -quiet DATAPATH_NET_DELAY $tp] ns"
    puts $fh $l
    puts $l
    puts $fh "      startpoint [get_property -quiet STARTPOINT_PIN $tp]"
    puts $fh "      endpoint   [get_property -quiet ENDPOINT_PIN $tp]"
}

# Routing completeness, for a like-for-like comparison with nextpnr's
# "0 unrouted / 0 overused".
#
# Do NOT hand-roll this as
#     get_nets -filter {ROUTE_STATUS != ROUTED && ROUTE_STATUS != INTRASITE}
# The first version did, and reported "7042 nets not fully routed" on a route
# that Vivado's own report_route_status called complete (Unrouted Nets = 0,
# Node Overlaps = 0, 0 critical warnings). ROUTE_STATUS has several benign
# values beyond ROUTED/INTRASITE -- constant-driven and no-load nets among them
# -- so the filter counted healthy nets as failures and cast doubt on a good
# result. report_route_status is the authority; parse that instead.
puts $fh ""
set rs [report_route_status -return_string]
foreach key {"Number of Unrouted Nets" "Number of Node Overlaps"} {
    foreach line [split $rs "\n"] {
        if {[string match "*$key*" $line]} {
            puts $fh "  [string trim $line]"
            puts "  [string trim $line]"
            break
        }
    }
}
close $fh
puts "wrote $out"
