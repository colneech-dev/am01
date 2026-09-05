# AtomMiner AM01 -- QMTECH Kintex-7 + Raspberry Pi CM4 variant, design proposal
# Copyright 2015-2022 AtomMiner <atom@atomminer.com>
#
# This code is free software; you can redistribute it and/or modify it
# under the terms of the BSD 3-Clause License as published by the Free
# Software Foundation; See COPYING for more details.
#
# Full non-interactive build: create the project (via build.tcl), run
# synthesis, run implementation through bitstream, and report where the
# result landed. Companion to build.tcl, which deliberately stops after
# project creation for interactive use -- this is the "just build it"
# variant for scripted/CI-style runs.
#
# Usage:
#   cd hardware/qmtech-kintex7/vivado
#   vivado -mode batch -source build_full.tcl
# Absolute -- see the note in build.tcl. build.tcl resets this when sourced
# below, but it is used to FIND build.tcl first, so it has to be right here too.
set script_dir [file normalize [file dirname [info script]]]
source [file join $script_dir build.tcl]

puts "----------------------------------------------------------------------"
puts "==> [1/2] synthesis"
launch_runs synth_1 -jobs [expr {max(1, [get_param general.maxThreads])}]
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
if {$synth_status ne "synth_design Complete!"} {
    error "synthesis did not complete cleanly: $synth_status"
}

open_run synth_1
set timing_rpt [file join $proj_dir "${proj_name}_timing_synth.rpt"]
report_timing_summary -file $timing_rpt
puts "    post-synth timing summary: $timing_rpt"
close_design

puts "==> [2/2] implementation + bitstream"
launch_runs impl_1 -to_step write_bitstream -jobs [expr {max(1, [get_param general.maxThreads])}]
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
if {$impl_status ne "write_bitstream Complete!"} {
    error "implementation/bitstream did not complete cleanly: $impl_status"
}

set bit_file [file join $proj_dir "${proj_name}.runs" impl_1 "am01_qmtech_top.bit"]
set impl_timing_rpt [file join $proj_dir "${proj_name}_timing_impl.rpt"]
open_run impl_1
report_timing_summary -file $impl_timing_rpt

# ---- archive it, before anything can delete the run directory -----------
#
# BEFORE close_design, deliberately: the frequency below is read off the live
# clock object, and there are no clocks once the design is closed. Closing
# first would have named every artifact 0.00MHz.
#
# artifacts/ is the only copy that outlives a rebuild. Doing this by hand is
# what lost a good 225MHz bitstream on 2026-09-05: the next build began with
# `rm -rf build` and an hour of compute went with it.
#
# The frequency comes from the design rather than from a variable someone has
# to remember to update -- it is read back off the actual clock object, so the
# name cannot disagree with what was built.
set art_dir [file join $script_dir artifacts]
file mkdir $art_dir

set hash_mhz 0.0
foreach clk [get_clocks] {
    set nm [get_property NAME $clk]
    # clkout1_unbuf is clk_h, the hash clock. sys_clk_50m and clkfb are not
    # interesting and clkout0_unbuf is clk_2x, which is unused here.
    if {[string match "*clkout1*" $nm]} {
        set per [get_property PERIOD $clk]
        if {$per > 0} { set hash_mhz [expr {1000.0 / $per}] }
    }
}

set stamp [clock format [clock seconds] -format "%m%d-%H%M"]
set art [file join $art_dir \
             [format "am01_%.2fMHz_%s.bit" $hash_mhz $stamp]]
if {[file exists $bit_file]} {
    file copy -force $bit_file $art
    # The reports too: a bitstream whose timing nobody can look up is a
    # bitstream nobody should flash.
    catch {file copy -force $impl_timing_rpt \
               [file join $art_dir [format "timing_%.2fMHz_%s.rpt" $hash_mhz $stamp]]}
    puts "ARCHIVED: $art"
}

close_design

puts "----------------------------------------------------------------------"
puts "BUILD_COMPLETE"
puts "Bitstream:        $bit_file"
puts "Post-synth timing: $timing_rpt"
puts "Post-impl timing:  $impl_timing_rpt"
puts "----------------------------------------------------------------------"
