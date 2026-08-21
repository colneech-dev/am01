# What Fmax does Vivado actually achieve on this design?
#
# WHY: with block RAM finally in nextpnr's timing graph, openXC7 reports
# clk_h = 65.19 MHz against a 133.33 MHz target. Every earlier openXC7 number
# (94-135 MHz) was fabric-only -- RAMB ports fell through to TMG_IGNORE, so all
# 420 memories were invisible and the reported Fmax was just the worst
# LUT-to-LUT path on a design that is 47% BRAM.
#
# Vivado's timing engine has always seen the BRAM paths. So its number on its own
# routed checkpoint is the reference:
#
#   * Vivado also lands near 65 MHz  -> our model is right, and the design
#     genuinely cannot run at 133.33 MHz. The mux2 work becomes necessary,
#     not optional.
#   * Vivado meets 133.33 MHz        -> either our BRAM numbers are wrong, or
#     Vivado's placement is dramatically better on the sbox paths. Either way
#     the 65 MHz figure needs re-examining before anyone acts on it.
#
# CAVEAT: this checkpoint is NUM_MINERS=2 (840 BRAMs); the openXC7 runs are
# NUM_MINERS=1 (420). Not a like-for-like comparison of congestion, but the sbox
# critical-path STRUCTURE is identical, which is what we are asking about.
#
# Run:  vivado -mode batch -source vivado_timing_check.tcl
# Out:  vivado_timing_check.txt

set dcp ../vivado/build/am01_qmtech_kintex7.runs/impl_1/am01_qmtech_top_routed.dcp
set out vivado_timing_check.txt

if {![file exists $dcp]} { puts "ERROR: no checkpoint at $dcp"; exit 1 }
open_checkpoint $dcp

set fh [open $out w]
puts $fh "part  : [get_property PART [current_design]]"
puts $fh "brams : [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB18*}]]"
puts $fh ""

puts $fh "== clocks =="
foreach clk [get_clocks] {
    puts $fh [format "  %-12s period %s ns  (%.2f MHz)" \
        [get_property NAME $clk] [get_property PERIOD $clk] \
        [expr {1000.0 / [get_property PERIOD $clk]}]]
}
puts $fh ""

puts $fh "== worst slack per clock, and achievable Fmax =="
foreach clk [get_clocks] {
    set nm [get_property NAME $clk]
    set per [get_property PERIOD $clk]
    set p [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 \
             -from [get_clocks $nm] -to [get_clocks $nm]]
    if {[llength $p] == 0} { puts $fh "  $nm : no intra-clock paths"; continue }
    set slack [get_property SLACK $p]
    # Achievable period = required period minus the slack we have spare.
    set achievable [expr {$per - $slack}]
    puts $fh [format "  %-12s WNS %7.3f ns  -> achievable %.3f ns = %.2f MHz" \
        $nm $slack $achievable [expr {1000.0 / $achievable}]]
}
puts $fh ""

puts $fh "== does the critical path start at a BRAM? =="
foreach clk [get_clocks] {
    set nm [get_property NAME $clk]
    set p [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 \
             -from [get_clocks $nm] -to [get_clocks $nm]]
    if {[llength $p] == 0} { continue }
    puts $fh "  $nm"
    puts $fh "    startpoint : [get_property STARTPOINT_PIN $p]"
    puts $fh "    endpoint   : [get_property ENDPOINT_PIN $p]"
    puts $fh "    logic      : [get_property DATAPATH_LOGIC_DELAY $p] ns"
    puts $fh "    net        : [get_property DATAPATH_NET_DELAY $p] ns"
    puts $fh "    total      : [get_property DATAPATH_DELAY $p] ns"
}

close $fh
puts "wrote $out"
