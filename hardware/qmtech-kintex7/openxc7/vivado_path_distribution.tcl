# Is the 15 ns net one bad net, or the tip of a distribution?
#
# The worst path on the nextpnr placement is a flop-to-flop net with no logic
# between the endpoints: logic 0.322 ns, net 15.104 ns, endpoints 132 slice rows
# apart. That single path caps the design at 63.55 MHz.
#
# But a single pathological net and a systemic placement failure call for
# completely different fixes, and the worst-path report cannot tell them apart:
#
#   - one outlier   -> a legalisation escape; cap the repair search radius
#   - a long tail   -> HeAP itself is not preserving locality; fixing one net
#                      just promotes the next one and gains almost nothing
#
# This reports the worst 200 setup paths so the shape is visible rather than
# inferred. Run against the already-routed checkpoint, so it costs a reload
# rather than a place-and-route.
#
# Run:  vivado -mode batch -source vivado_path_distribution.tcl
# Out:  vivado_path_distribution.txt

set dcp    vivado_routed_nextpnr_placement.dcp
set pinxdc ../xdc/qmtech_xc7k325t_pinout.xdc
set out    vivado_path_distribution.txt

foreach f [list $dcp $pinxdc] {
    if {![file exists $f]} { puts "ERROR: missing $f"; exit 1 }
}

open_checkpoint $dcp
read_xdc $pinxdc

set paths [get_timing_paths -quiet -setup -max_paths 200 -nworst 200]
puts "collected [llength $paths] paths"
if {[llength $paths] == 0} { puts "ERROR: no paths"; exit 1 }

set fh [open $out w]
puts $fh "# Worst 200 setup paths on the nextpnr placement, routed by Vivado"
puts $fh "# columns: slack_ns  logic_ns  net_ns  net_frac"
puts $fh ""

# Buckets over net delay, to show the shape at a glance.
array set bucket {}
foreach b {0 2 4 8 12 16} { set bucket($b) 0 }
set n 0
set sum_net 0.0
set worst_logic 0.0

foreach p $paths {
    set s   [get_property SLACK $p]
    set lg  [get_property -quiet DATAPATH_LOGIC_DELAY $p]
    set nt  [get_property -quiet DATAPATH_NET_DELAY $p]
    if {$lg eq "" || $nt eq ""} { continue }
    incr n
    set sum_net [expr {$sum_net + $nt}]
    if {$lg > $worst_logic} { set worst_logic $lg }
    set tot [expr {$lg + $nt}]
    set frac [expr {$tot > 0 ? $nt / $tot : 0}]
    if {$n <= 20} {
        puts $fh [format "  %8.3f  %7.3f  %7.3f  %5.1f%%" $s $lg $nt [expr {$frac * 100}]]
    }
    # bucket by net delay
    set b 0
    foreach edge {16 12 8 4 2} {
        if {$nt >= $edge} { set b $edge; break }
    }
    incr bucket($b)
}

puts $fh ""
puts $fh "# net-delay distribution over $n paths"
foreach b {16 12 8 4 2 0} {
    set label [expr {$b == 16 ? ">=16ns" : [format "%2d-%2dns" $b [expr {$b == 12 ? 16 : $b == 8 ? 12 : $b == 4 ? 8 : $b == 2 ? 4 : 2}]]}]
    puts $fh [format "  %-8s %5d" $label $bucket($b)]
    puts [format "  %-8s %5d" $label $bucket($b)]
}
puts $fh ""
puts $fh [format "# mean net delay %.3f ns over %d paths; worst logic delay %.3f ns" \
            [expr {$n > 0 ? $sum_net / $n : 0}] $n $worst_logic]
puts [format "mean net delay %.3f ns; worst logic delay %.3f ns" \
        [expr {$n > 0 ? $sum_net / $n : 0}] $worst_logic]
close $fh
puts "wrote $out"
