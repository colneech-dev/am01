#  AtomMiner AM01 -- QMTECH Kintex-7 + Raspberry Pi CM4 variant, design proposal
#  Copyright 2015-2022 AtomMiner <atom@atomminer.com>
#
# This code is free software; you can redistribute it and/or modify it
# under the terms of the BSD 3-Clause License as published by the Free
# Software Foundation; See COPYING for more details.
#
# Non-interactive Vivado project generator for the QMTECH XC7K325T + CM4
# variant -- builds the .xpr from source files directly, no IP Integrator
# block design needed (clocking is a hand-written MMCME2_BASE instance,
# see ../hdl/clk_gen_hash.v).
#
# Usage:
#   cd hardware/qmtech-kintex7/vivado
#   vivado -mode batch -source build.tcl
#
# Targets the manual's documented toolchain (Vivado 2018.3) but should
# work on newer 2018.x/2019.x releases too. Not run/verified against
# real Vivado as part of this repo -- see ../README.md's "what's still
# needed" list.

set part      xc7k325tffg676-1
set proj_name am01_qmtech_kintex7
set script_dir [file dirname [info script]]
set proj_dir   [file join $script_dir build]

set repo_root    [file normalize [file join $script_dir .. .. ..]]
set odocrypt_hdl [file join $repo_root exmaples odocrypt fpga src hdl]
set this_hdl     [file join $repo_root hardware qmtech-kintex7 hdl]
set this_xdc     [file join $repo_root hardware qmtech-kintex7 xdc]

create_project $proj_name $proj_dir -part $part -force

# Only the algorithm/interface-agnostic sources from the odocrypt example
# (encrypt.v, keccak800.v, miner.v, and atomminer_misc.v's odo_block_data
# / host_break_sm) -- deliberately NOT atomminer_odocrypt.v, usb3_interface.v,
# usb3_sm_v3.v, or the artix200_v3_clocking/usb3_system_ram/xadc_artix200_v0
# IP, all of which are specific to the stock AM01's FX3/Artix-7 setup and
# have no place in this variant.
add_files -norecurse [list \
    [file join $odocrypt_hdl encrypt.v] \
    [file join $odocrypt_hdl keccak800.v] \
    [file join $odocrypt_hdl miner.v] \
    [file join $odocrypt_hdl atomminer_misc.v] \
    [file join $this_hdl clk_gen_hash.v] \
    [file join $this_hdl odocrypt_gpio_wrapper.v] \
    [file join $this_hdl am01_qmtech_top.v] \
]

add_files -fileset constrs_1 -norecurse [file join $this_xdc qmtech_xc7k325t_pinout.xdc]

set_property top am01_qmtech_top [current_fileset]
update_compile_order -fileset sources_1

puts "----------------------------------------------------------------------"
puts "Project created: $proj_dir/$proj_name.xpr"
puts "Next steps (interactively, or append to this script):"
puts "  launch_runs synth_1 -jobs 4; wait_on_run synth_1"
puts "  open_run synth_1; report_timing_summary -file timing_synth.rpt"
puts "    (use this to re-tune clk_gen_hash's CLKOUT0_DIVIDE -- see its"
puts "     header comment, the 125MHz default is an untuned placeholder)"
puts "  launch_runs impl_1 -to_step write_bitstream -jobs 4"
puts "----------------------------------------------------------------------"
