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
# WNS and WHS are the worst SETUP and HOLD paths, and with no -from/-to
# filter those really are design-wide -- a failing endpoint elsewhere cannot
# be worse than the worst one. But pulse width, min period and max skew are
# NOT timing paths, so get_timing_paths cannot see them at all: a design can
# pass both checks below with failing pulse-width endpoints. Check the run's
# own properties, which cover all three.
set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
set wpws [get_property STATS.WPWS [get_runs impl_1]]
if {$wns eq "" || $whs eq ""} {
    # Opened from a standalone checkpoint, so the run properties are absent.
    # Fall back to guarded path queries, and say so rather than pretending
    # pulse width was checked.
    set sp [get_timing_paths -delay_type max -max_paths 1 -quiet]
    set hp [get_timing_paths -delay_type min -max_paths 1 -quiet]
    set wns [expr {[llength $sp] ? [get_property SLACK [lindex $sp 0]] : 0.0}]
    set whs [expr {[llength $hp] ? [get_property SLACK [lindex $hp 0]] : 0.0}]
    set wpws "n/a"
    puts "BITGEN: standalone checkpoint -- pulse width NOT checked here;"
    puts "        read the summary report before flashing."
}
puts [format "BITGEN: WNS %s  WHS %s  WPWS %s" $wns $whs $wpws]
if {$wns < 0 || $whs < 0 || ($wpws ne "n/a" && $wpws < 0)} {
    puts "BITGEN: REFUSING -- checkpoint does not meet timing."
    exit 1
}
set bit [file join $script_dir artifacts am01_mux4_133.33MHz_epoch1789344000_DO-NOT-FLASH-BEFORE-2026-09-14.bit]
write_bitstream -force $bit
puts "BITGEN: wrote $bit"
