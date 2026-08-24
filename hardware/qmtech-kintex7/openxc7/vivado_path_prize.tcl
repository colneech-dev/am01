# How much Fmax is actually on the table?
#
# The worst 200 setup paths on the nextpnr placement ALL sat in the 12-16 ns
# net-delay bucket, so that sample never showed where the distribution falls
# off. Without that, "fix the stretched connections" has no size attached to
# it -- and the answer decides whether the placement work is worth doing at all:
#
#   * if removing the long tail lands us near 150 MHz, this is the whole game
#   * if it lands near 95 MHz, the tail is a red herring and the limit is
#     somewhere else entirely
#
# This walks much deeper into the path list and reports the net-delay
# percentiles, so the ceiling implied by "fix the tail" is a number.
#
# Reported Fmax at a given path delay assumes the 7.500 ns clk_h target:
#   achieved = logic + net + clocking overhead; we approximate by taking the
#   path's own (period - slack) and recomputing against the Nth-worst path.
#
# Run:  vivado -mode batch -source vivado_path_prize.tcl
# Out:  vivado_path_prize.txt

set dcp    vivado_routed_nextpnr_placement.dcp
set pinxdc ../xdc/qmtech_xc7k325t_pinout.xdc
set out    vivado_path_prize.txt

foreach f [list $dcp $pinxdc] {
    if {![file exists $f]} { puts "ERROR: missing $f"; exit 1 }
}

open_checkpoint $dcp
read_xdc $pinxdc

# -nworst 1 per endpoint avoids the 4x duplication seen with -nworst 200,
# which made 200 "paths" only ~50 distinct ones.
set paths [get_timing_paths -quiet -setup -max_paths 4000 -nworst 1]
set n [llength $paths]
puts "collected $n distinct paths"
if {$n == 0} { puts "ERROR: no paths"; exit 1 }

set fh [open $out w]
puts $fh "# Net-delay percentiles on the nextpnr placement, routed by Vivado"
puts $fh "# $n distinct paths (-nworst 1, so one per endpoint)"
puts $fh ""

set rows {}
foreach p $paths {
    set s  [get_property SLACK $p]
    set lg [get_property -quiet DATAPATH_LOGIC_DELAY $p]
    set nt [get_property -quiet DATAPATH_NET_DELAY $p]
    if {$lg eq "" || $nt eq ""} { continue }
    lappend rows [list $s $lg $nt]
}
set m [llength $rows]
puts $fh "# usable rows: $m"
puts $fh ""

# Paths come back worst-first. Index i therefore = the (i+1)-th worst path.
# "If the worst K were fixed, the limit would be the (K+1)-th path."
puts $fh "# If the worst K paths were brought in line, the next limit would be:"
puts $fh "#   K     slack_ns   logic_ns   net_ns    implied_MHz"
foreach k {0 10 25 45 50 100 200 400 800 1600 3200} {
    if {$k >= $m} { continue }
    set r [lindex $rows $k]
    set s  [lindex $r 0]
    set lg [lindex $r 1]
    set nt [lindex $r 2]
    # clk_h period is 7.500 ns; achieved = period - slack
    set ach [expr {7.500 - $s}]
    set mhz [expr {$ach > 0 ? 1000.0 / $ach : 0}]
    set line [format "  %5d   %8.3f   %8.3f  %7.3f    %7.2f" $k $s $lg $nt $mhz]
    puts $fh $line
    puts $line
}

# Net-delay histogram over everything, to see the shape.
array set b {}
foreach edge {0 1 2 4 6 8 10 12 14 16} { set b($edge) 0 }
foreach r $rows {
    set nt [lindex $r 2]
    set put 0
    foreach edge {16 14 12 10 8 6 4 2 1} {
        if {$nt >= $edge} { incr b($edge); set put 1; break }
    }
    if {!$put} { incr b(0) }
}
puts $fh ""
puts $fh "# net-delay histogram (ns)"
foreach edge {16 14 12 10 8 6 4 2 1 0} {
    puts $fh [format "  >=%2d ns : %6d" $edge $b($edge)]
}
close $fh
puts "wrote $out"
