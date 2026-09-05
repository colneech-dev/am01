#  AM01 QMTECH Kintex-7 -- 4-INSTANCE SHARED-BRAM EXPERIMENT
#
#  EXPERIMENT, NOT A SHIPPING BUILD. Its own project directory (build_mux4),
#  its own top (am01_qmtech_top_mux4), and its own copies of every file that
#  differs, all under ../hdl/mux4/. Nothing the shipping build.tcl reads is
#  touched, because a 200MHz bitstream built from those files is flashed and
#  earning right now.
#
#  THE QUESTION THIS ANSWERS. tools/mux2_transform.py collapses each PAIR of
#  large S-box slots that read the same table into ONE block RAM, time-
#  multiplexed on clk_2x. That halves BRAM per instance, so four instances fit
#  where two fit today:
#
#      stock   2 instances x 420 RAMB18 = 840 of 890  (94%)
#      mux2    4 instances x 210 RAMB18 = 840 of 890  (94%)
#
#  Whether it is FASTER depends entirely on whether the muxed address path
#  closes at clk_2x, and that has never been measured -- openXC7 cannot time
#  paths adjacent to a block RAM at all (openxc7/README.md), which is precisely
#  what this path is. Vivado is the only tool that can answer it, so the number
#  to read out of this run is the clk_2x WNS, not the bitstream.
#
#  WHAT TO EXPECT. Routing alone accounts for 3.201ns of the 4.055ns critical
#  path in the shipping 200MHz build, against a 2.5ns clk_2x budget at
#  clk_h=200MHz. So clk_h almost certainly has to come down; the design trades
#  clock for instances, and only wins if 4 x (reduced clk_h) beats
#  2 x 200MHz. Break-even is clk_h = 100MHz.
#
#  DO NOT FLASH THE RESULT until sim/run_encrypt_equiv.sh passes against
#  encrypt_mux2.v. A core that runs fast and computes wrong digests has
#  happened on this project before and cost a full epoch.
#
#  Usage:
#    cd hardware/qmtech-kintex7/vivado
#    vivado -mode batch -source build_mux4.tcl

set part      xc7k325tffg676-1
set proj_name am01_qmtech_mux4
# Absolute. A relative script_dir cost a completed synthesis on 2026-09-04
# when a report write resolved against a working directory that had moved --
# see the longer note in build.tcl.
set script_dir [file normalize [file dirname [info script]]]
set proj_dir   [file join $script_dir build_mux4]

set repo_root    [file normalize [file join $script_dir .. .. ..]]
set odocrypt_hdl [file join $repo_root hdl odocrypt]
set this_hdl     [file join $repo_root hardware qmtech-kintex7 hdl]
set mux4_hdl     [file join $this_hdl mux4]
set this_xdc     [file join $repo_root hardware qmtech-kintex7 xdc]

# ---- the generated core must match the encrypt.v it came from ----------
#
# hdl/mux4/encrypt_mux2.v is NOT in git. It is derived from
# hdl/odocrypt/encrypt.v, which is itself regenerated every OdoCrypt epoch and
# may or may not carry --bram-out-reg -- and the muxed S-box has to match that
# choice exactly. A 2-clk_h muxed box against a 1-clk_h encrypt.v (or the
# reverse) synthesises cleanly, fits, and computes garbage; that cost a full
# build on 2026-09-04 before sim/run_encrypt_equiv.sh caught it.
#
# So refuse to build from a core that is missing or older than its source,
# rather than silently producing a bitstream for the wrong cipher. The
# transform measures the latency itself, so regenerating is always safe.
set encrypt_v  [file join $odocrypt_hdl encrypt.v]
set mux2_v     [file join $mux4_hdl encrypt_mux2.v]
set regen_cmd  "python ../tools/mux2_transform.py ../../../hdl/odocrypt/encrypt.v ../hdl/mux4/encrypt_mux2.v"
if {![file exists $mux2_v]} {
    puts "MUX4: $mux2_v does not exist."
    puts "MUX4: generate it first:  $regen_cmd"
    exit 1
}
if {[file mtime $mux2_v] < [file mtime $encrypt_v]} {
    puts "MUX4: $mux2_v is OLDER than encrypt.v -- it is stale."
    puts "MUX4: regenerate it:  $regen_cmd"
    exit 1
}

create_project $proj_name $proj_dir -part $part -force

# DELIBERATELY ABSENT, and each for a reason that is a hard error rather than
# a preference:
#
#   encrypt.v          -- 81 of its module names collide with encrypt_mux2.v.
#   miner.v            -- its odo_keccak instantiates encrypt_4encrypt with
#                         FIVE positional arguments; the muxed core has SEVEN
#                         ports (clk2x, phase). cmp_256, the one module from it
#                         this build needs, is lifted into mux4/cmp_256.v.
#   miner_pipelined.v  -- instantiates the odo_keccak that miner.v would have
#                         defined. mux4/miner_mux4.v supplies the clk2x-carrying
#                         miner_pipelined_mux4 instead.
#   sbox_large_mux2.v  -- not referenced: the transform emitted its own ten
#                         encrypt_4sbox_largeN_mux2 modules inline.
#
# keccak800.v and atomminer_misc.v are shared with the shipping build unchanged
# (keccak_hasher and odo_block_data); neither is touched by the transform.
add_files -norecurse [list \
    [file join $mux4_hdl     encrypt_mux2.v] \
    [file join $odocrypt_hdl keccak800.v] \
    [file join $mux4_hdl     cmp_256.v] \
    [file join $mux4_hdl     miner_mux4.v] \
    [file join $odocrypt_hdl atomminer_misc.v] \
    [file join $this_hdl     clk_gen_hash.v] \
    [file join $this_hdl     found_path.v] \
    [file join $this_hdl     uart_bridge.v] \
    [file join $mux4_hdl     odocrypt_gpio_wrapper_mux4.v] \
    [file join $mux4_hdl     am01_qmtech_top_mux4.v] \
]

# The same pinout: the experiment changes what is inside the part, not what
# leaves it. Port names are identical, so every get_ports still resolves.
add_files -fileset constrs_1 -norecurse \
    [file join $this_xdc qmtech_xc7k325t_pinout.xdc]

set_property top am01_qmtech_top_mux4 [current_fileset]
update_compile_order -fileset sources_1

# Synthesis alone is enough to answer the first question -- does it FIT? Four
# muxed instances are predicted at 840 RAMB18 of 890, and if the transform's
# BRAM inference does not hold, that shows up here rather than three hours into
# implementation.
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "MUX4: SYNTHESIS FAILED -- see $proj_dir/${proj_name}.runs/synth_1/"
    exit 1
}

open_run synth_1 -name synth_1
puts "----------------------------------------------------------------------"
puts "MUX4 post-synthesis utilisation (RAMB18 is the number that matters):"
report_utilization -file [file join $script_dir mux4_synth_util.rpt]
foreach line [split [report_utilization -return_string] "\n"] {
    if {[string match "*RAMB*" $line] || [string match "*Slice LUTs*" $line]} {
        puts "  $line"
    }
}
report_timing_summary -file [file join $script_dir mux4_synth_timing.rpt]
puts "----------------------------------------------------------------------"

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "MUX4: IMPLEMENTATION FAILED -- see $proj_dir/${proj_name}.runs/impl_1/"
    exit 1
}

open_run impl_1
report_timing_summary -file [file join $script_dir mux4_impl_timing.rpt]
report_utilization    -file [file join $script_dir mux4_impl_util.rpt]

# THE ANSWER. clk_2x's slack is the whole experiment: if it is negative, clk_h
# has to fall by that much and the instance count was bought with clock.
puts "----------------------------------------------------------------------"
puts "MUX4 RESULT -- worst slack per clock:"
# -quiet plus a length check: not every clock captures paths. clkfb is the
# MMCM feedback and captures none, so an unguarded get_property errors out on
# it -- which on 2026-09-05 killed this loop after the first clock and printed
# nothing for clk_h or clk_2x, the only two anyone wants.
foreach clk [get_clocks] {
    set nm     [get_property NAME $clk]
    set period [get_property PERIOD $clk]
    set setup  [get_timing_paths -to $clk -max_paths 1 -delay_type max -quiet]
    set hold   [get_timing_paths -to $clk -max_paths 1 -delay_type min -quiet]
    if {[llength $setup] == 0} {
        puts [format "  %-16s %8.3f ns  (no captured paths)" $nm $period]
        continue
    }
    set wns [get_property SLACK [lindex $setup 0]]
    set whs "n/a"
    if {[llength $hold] > 0} { set whs [get_property SLACK [lindex $hold 0]] }
    # The achievable period is what decides whether to retune the MMCM: a
    # design that misses its target is not flashable even when the frequency
    # it DID reach would have been acceptable.
    set achievable [expr {$period - $wns}]
    puts [format "  %-16s target %7.3f ns  WNS %7.3f  WHS %7s  -> needs %7.3f ns (%6.2f MHz)" \
              $nm $period $wns $whs $achievable [expr {1000.0 / $achievable}]]
}
puts ""
puts "  reports: mux4_impl_timing.rpt, mux4_impl_util.rpt"
puts "  DO NOT FLASH until sim/run_encrypt_equiv.sh passes on encrypt_mux2.v."
puts "----------------------------------------------------------------------"
