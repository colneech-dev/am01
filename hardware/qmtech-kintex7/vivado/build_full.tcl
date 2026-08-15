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
set script_dir [file dirname [info script]]
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
close_design

puts "----------------------------------------------------------------------"
puts "BUILD_COMPLETE"
puts "Bitstream:        $bit_file"
puts "Post-synth timing: $timing_rpt"
puts "Post-impl timing:  $impl_timing_rpt"
puts "----------------------------------------------------------------------"
