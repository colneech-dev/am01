# Can Vivado fix the muxed design's hold violations in place?
#
# IMPLEMENTATION-REVIEW.md section 4g diagnoses 12,545 failing hold endpoints,
# essentially all of them on clk_h <-> clk_2x crossings, caused by the two
# clocks travelling through two different BUFGs with 0.331ns of skew between
# them. The structural fix is to delete the second clock domain and use a
# clock enable -- a large change to the transform, the wrapper and the XDC.
#
# THIS SCRIPT EXISTS TO AVOID DOING THAT WORK UNNECESSARILY. Hold violations
# are fixed by inserting delay, and route_design already tries. If a post-route
# pass can clear them, the rewrite is not needed and the muxed design only
# needs an MMCM retune to be flashable.
#
# The expectation is that it CANNOT: the device is at 94% block RAM and 81%
# LUT, and 4e already showed the placer could not find a free slice next to a
# BRAM for a fanout-2 flop. Inserting ~12,500 delay elements into that is
# implausible. But an hour of otherwise-idle machine time is cheap against
# thirty hours of rewriting, so it gets asked rather than assumed.
#
# Reads the routed checkpoint and writes nothing the build depends on.
#
#   vivado -mode batch -source try_hold_fix.tcl

set script_dir [file normalize [file dirname [info script]]]
set impl_dir   [file join $script_dir build_mux4 am01_qmtech_mux4.runs impl_1]
set dcp        [file join $impl_dir am01_qmtech_top_mux4_routed.dcp]

if {![file exists $dcp]} {
    puts "HOLDFIX: no routed checkpoint at $dcp"
    exit 1
}

open_checkpoint $dcp

proc hold_state {tag} {
    set whs [get_property SLACK [lindex [get_timing_paths -delay_type min -max_paths 1 -quiet] 0]]
    puts [format "HOLDFIX %-8s WHS %8.3f ns" $tag $whs]
    return $whs
}

puts "----------------------------------------------------------------------"
set before [hold_state "BEFORE"]

# Hold fixing lives in route_design, not phys_opt_design -- phys_opt works on
# setup. -tns_cleanup asks the router to revisit paths it had given up on.
puts "HOLDFIX: re-routing with hold fixing"
route_design -directive Explore -tns_cleanup

set after [hold_state "AFTER"]
puts "----------------------------------------------------------------------"

report_timing_summary -file [file join $script_dir mux4_holdfix_timing.rpt]

if {$after >= 0} {
    puts "HOLDFIX: RESOLVED -- hold is clean. The clock-enable rewrite is NOT"
    puts "         needed for this; retune the MMCM and re-check setup."
} else {
    puts [format "HOLDFIX: STILL FAILING (%.3f -> %.3f ns)." $before $after]
    puts "         Confirms section 4g: this is not a routing problem, it is"
    puts "         two BUFGs. The clock-enable rewrite is the way."
}
puts "HOLDFIX: report at mux4_holdfix_timing.rpt"
