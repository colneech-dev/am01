# Why is the worst path 15.104 ns of net delay when 20,000 measured connections
# on the SAME routed design top out at 7.828 ns?
#
# The calibration (vivado_net_delay_calib5.csv, 20k rows) fits
#     delay_ps = 501.7 + 30.04 * manhattan
# so a manhattan-153 connection should cost ~5.1 ns. nextpnr's predictDelay
# says 5.625 ns -- within 10% of the empirical fit. Yet the reported worst path
# carries 15.104 ns. Either that path is several nets, or its net is a ~3x
# outlier against its own length. This decides which, and therefore decides
# whether the delay MODEL or the ROUTE is at fault.
#
# Out: vivado_worst_path_anatomy.txt

set dcp vivado_routed_nextpnr_placement.dcp
set out vivado_worst_path_anatomy.txt
if {![file exists $dcp]} { puts "ERROR: no checkpoint at $dcp"; exit 1 }
open_checkpoint $dcp
read_xdc ../xdc/qmtech_xc7k325t_pinout.xdc

set fh [open $out w]
proc emit {fh s} { puts $fh $s ; puts $s }

set tp [get_timing_paths -setup -max_paths 3 -nworst 1 -sort_by slack]
emit $fh "# worst setup paths on the nextpnr placement, routed by Vivado"
emit $fh ""

foreach p $tp {
    emit $fh "==== slack [get_property SLACK $p]  logic [get_property -quiet DATAPATH_LOGIC_DELAY $p]  net [get_property -quiet DATAPATH_NET_DELAY $p]"
    emit $fh "     start [get_property -quiet STARTPOINT_PIN $p]"
    emit $fh "     end   [get_property -quiet ENDPOINT_PIN $p]"

    # How many NETS does this path actually traverse?
    set nets [get_nets -quiet -of_objects $p]
    emit $fh "     nets on path: [llength $nets]"
    foreach nn $nets {
        set fo [get_property -quiet FLAT_PIN_COUNT $nn]
        set rs [get_property -quiet ROUTE_STATUS $nn]
        # node count is the honest detour metric: a straight route uses few
        set nodes [get_nodes -quiet -of_objects $nn]
        set dlys [get_net_delays -quiet -of_objects $nn]
        set worst 0
        foreach d $dlys {
            set v [get_property -quiet SLOW_MAX $d]
            if {$v ne "" && $v > $worst} { set worst $v }
        }
        emit $fh [format "       net %-70s fanout %-6s status %-10s nodes %-6s worstsink %s ps" \
                    $nn $fo $rs [llength $nodes] $worst]
    }
    emit $fh ""
}

# Full textual report for the single worst path -- per-element incremental delay
emit $fh "==== full report_timing for the worst path ===="
close $fh
report_timing -setup -max_paths 1 -nworst 1 -path_type full_clock_expanded \
    -input_pins -file $out -append
puts "wrote $out"
exit 0
