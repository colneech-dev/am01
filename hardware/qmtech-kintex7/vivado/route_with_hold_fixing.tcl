# Route the muxed design WITH HOLD FIXING ACTUALLY ENABLED.
#
# THE EXPERIMENT THAT SHOULD HAVE RUN FIRST. Every muxed build so far contains
# this, and it was never read:
#
#   WARNING: [Route 35-514] Design has a large number of hold violators.
#   This is likely a design or constraint issue. Router is turning off hold
#   fixing. Resolution: ... You can disable hold expansion based bailout to
#   continue fixing hold using the following TCL command in a pre-route TCL
#   script: set_param route.enableHoldExpnBailout 0
#
# So the 7,807 failing hold endpoints in IMPLEMENTATION-REVIEW.md 4g/4h are
# not a design that cannot be fixed. They are a design the router DECLINED to
# fix, having tripped a violator-count heuristic, and it names the override in
# the log.
#
# THE CONTROL THAT MAKES THIS DAMNING. The SHIPPING 2-instance build enters
# routing with worse total hold violation than the muxed one and comes out
# clean, because it never trips the bailout:
#
#   shipping   WHS -0.246  THS -1512.039   ->   WHS +0.026  THS 0.000
#   muxed      WHS -0.442  THS -16742.733  ->   bailout at Phase 5.2
#
# Section 4f read that same contrast as evidence for a clocking hypothesis
# ("every muxed build has them; no shipping build does"). It is evidence for a
# heuristic, and the heuristic is switchable.
#
# The earlier try_hold_fix.tcl did not test this either, and its log says so:
#
#   INFO: [Route 35-558] -tns_cleanup is called on fully routed design.
#   This will optimize the tns and all other options are ignored.
#
# -directive Explore was discarded, the iterations report WHS=N/A, and the run
# reverted to its input routing. "-0.413 -> -0.413" was the same netlist
# measured twice, not a failed repair.
#
# Routes from the PLACED checkpoint, not a routed one -- hold fixing happens
# during routing and cannot be bolted on afterwards.
#
#   vivado -mode batch -source route_with_hold_fixing.tcl
#
# Expect a long run: the warning itself says "potentially very long router run
# time", which is the price of the thing it was avoiding.

set script_dir [file normalize [file dirname [info script]]]
set impl_dir   [file join $script_dir build_mux4 am01_qmtech_mux4.runs impl_1]
set dcp        [file join $impl_dir am01_qmtech_top_mux4_physopt.dcp]

if {![file exists $dcp]} {
    puts "HOLDFIX2: no placed/physopt checkpoint at $dcp"
    exit 1
}

# BEFORE route_design, which is the whole point -- it is a pre-route setting.
set_param route.enableHoldExpnBailout 0
puts "HOLDFIX2: route.enableHoldExpnBailout = 0 (hold fixing will NOT bail out)"

open_checkpoint $dcp

puts "----------------------------------------------------------------------"
puts "HOLDFIX2: routing with hold fixing enabled"
route_design

set wns [get_property SLACK [lindex [get_timing_paths -delay_type max -max_paths 1 -quiet] 0]]
set whs [get_property SLACK [lindex [get_timing_paths -delay_type min -max_paths 1 -quiet] 0]]
puts "----------------------------------------------------------------------"
puts [format "HOLDFIX2 RESULT   WNS %8.3f ns   WHS %8.3f ns" $wns $whs]

report_timing_summary -file [file join $script_dir mux4_holdfixing_timing.rpt]
write_checkpoint -force [file join $impl_dir am01_qmtech_top_mux4_holdfixed.dcp]

if {$whs >= 0} {
    puts "HOLDFIX2: HOLD IS CLEAN. The violations were the router declining to"
    puts "          fix them, not two clock domains. Sections 4g/4h are wrong,"
    puts "          and the clock-enable rewrite is NOT needed for this."
    if {$wns >= 0} {
        puts "HOLDFIX2: setup is met too -- write a bitstream and validate it."
    } else {
        puts [format "HOLDFIX2: setup still short by %.3f ns -- drop one MMCM rung." $wns]
    }
} else {
    puts [format "HOLDFIX2: hold still failing (%.3f ns) WITH fixing enabled." $whs]
    puts "          THAT is the evidence 4g needed and never had."
}
puts "HOLDFIX2: report at mux4_holdfixing_timing.rpt"
