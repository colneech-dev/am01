# What IS the reported critical path?
#
# The routed checkpoint reports 63.55 MHz on the 7.500 ns domain with
# logic 0.322 ns / net 15.104 ns. That logic figure is an order of magnitude
# below the ~2.19 ns the Vivado-place+Vivado-route reference reports for the
# miner datapath, which is a strong hint the two numbers are not measuring the
# same path -- and therefore that 63.55 must not be compared against 158.81
# until the endpoints are known.
#
# This prints the startpoint, endpoint and clock of the worst path so the
# question can be settled by looking rather than by inference.

set dcp    vivado_routed_nextpnr_placement.dcp
set pinxdc ../xdc/qmtech_xc7k325t_pinout.xdc

open_checkpoint $dcp
read_xdc $pinxdc

foreach clk [get_clocks] {
    set nm  [get_property NAME $clk]
    set per [get_property PERIOD $clk]
    set tp [get_timing_paths -quiet -setup -max_paths 3 -nworst 3 \
              -from [get_clocks $nm] -to [get_clocks $nm]]
    if {[llength $tp] == 0} { continue }
    puts "=== clock $nm (period $per) ==="
    foreach p $tp {
        puts [format "  slack %8.3f  logic %s  net %s" \
                [get_property SLACK $p] \
                [get_property -quiet DATAPATH_LOGIC_DELAY $p] \
                [get_property -quiet DATAPATH_NET_DELAY $p]]
        puts "    start [get_property -quiet STARTPOINT_PIN $p]"
        puts "    end   [get_property -quiet ENDPOINT_PIN $p]"
    }
}
