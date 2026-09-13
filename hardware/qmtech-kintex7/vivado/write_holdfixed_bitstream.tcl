# Write a bitstream from the hold-fixed routed checkpoint.
#
# route_with_hold_fixing.tcl proved the muxed design meets timing once the
# router is allowed to fix hold (set_param route.enableHoldExpnBailout 0):
#
#   WNS +0.080 ns   0 failing of 252,722
#   WHS +0.035 ns   0 failing of 252,655
#   clk_2x 266.667 MHz   clk_h 133.333 MHz  ->  133.3 MH/s, +33%
#
# That checkpoint is routed but has no bitstream, because the experiment was
# asking a timing question. This turns it into something flashable.
#
# Epoch 1789344000, so it is valid only from 2026-09-14 00:00 UTC -- the same
# gate as the shipping epoch build.
set script_dir [file normalize [file dirname [info script]]]
set impl_dir   [file join $script_dir build_mux4 am01_qmtech_mux4.runs impl_1]
open_checkpoint [file join $impl_dir am01_qmtech_top_mux4_holdfixed.dcp]

# Re-assert rather than trust the filename: a bitstream written from a
# checkpoint that does not meet timing is exactly the artifact this project
# has been burned by before.
set wns [get_property SLACK [lindex [get_timing_paths -delay_type max -max_paths 1 -quiet] 0]]
set whs [get_property SLACK [lindex [get_timing_paths -delay_type min -max_paths 1 -quiet] 0]]
puts [format "BITGEN: WNS %.3f  WHS %.3f" $wns $whs]
if {$wns < 0 || $whs < 0} {
    puts "BITGEN: REFUSING -- checkpoint does not meet timing."
    exit 1
}
set bit [file join $script_dir artifacts am01_mux4_133.33MHz_epoch1789344000_DO-NOT-FLASH-BEFORE-2026-09-14.bit]
write_bitstream -force $bit
puts "BITGEN: wrote $bit"
