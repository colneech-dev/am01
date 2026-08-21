# Vivado route diff (openXC7 plan item 0.3)
#
# nextpnr-xilinx router2 leaves 143 arcs unrouted (down from 447 after the
# Phase 1.1 requeue fix). Vivado routes the same design successfully. This
# dumps the physical route Vivado used, so a known-good path can be compared
# against nextpnr's internal state.
#
# Target chosen from v19_unrouted_arcs.tsv: RAMB18_X1Y18 accounts for 11 of the
# 143 failures, and they come from just three nets -- each losing most of its
# own sinks. That is the "rigid route tree" signature: arcs route in fixed
# index order, an early arc fixes the driving pip, and router2 only allows
# re-entry to a wire already carrying the net via that same pip.
#
# THE QUESTION THIS ANSWERS:
#   How many distinct egress wires out of RAMB18_X1Y18 does Vivado use for
#   these nets, and what shape is the tree? If Vivado uses several independent
#   egresses (or a branch structure nextpnr cannot reach given its arc
#   ordering), that confirms whole-net ripup / arc reordering (plan 1.5, 1.7)
#   as the fix. If Vivado uses ONE egress that nextpnr also has available,
#   the block is elsewhere -- check reserved_net / checkPipAvail on those wires.
#
# Run:  vivado -mode batch -source vivado_route_diff.tcl
# Out:  vivado_route_diff.txt

set dcp ../vivado/build/am01_qmtech_kintex7.runs/impl_1/am01_qmtech_top_routed.dcp
set out vivado_route_diff.txt

if {![file exists $dcp]} {
    puts "ERROR: routed checkpoint not found: $dcp"
    exit 1
}
open_checkpoint $dcp

# nextpnr prints hierarchy with '.', Vivado uses '/'.
set targets {
    odocrypt_gpio_wrapper_inst/g_miner[0]/miner_top_inst/miner/worker/crypt/crypter/round15/mid[1][299]
    odocrypt_gpio_wrapper_inst/g_miner[0]/miner_top_inst/miner/worker/crypt/crypter/round15/mid[1][315]
    odocrypt_gpio_wrapper_inst/g_miner[0]/miner_top_inst/miner/worker/crypt/crypter/round15/mid[1][303]
}

set fh [open $out w]
puts $fh "# Vivado physical routes for nets nextpnr-xilinx could not fully route"
puts $fh "# checkpoint: $dcp"
puts $fh "# source BRAM of interest: RAMB18_X1Y18"
puts $fh ""

foreach n $targets {
    puts $fh "================================================================"
    puts $fh "NET (nextpnr name, '.' -> '/'): $n"

    set net [get_nets -quiet $n]
    if {[llength $net] == 0} {
        # Hierarchy/escaping may differ post-synthesis; fall back to a tail match.
        set leaf [lindex [split $n /] end]
        set net [get_nets -quiet -hierarchical -filter "NAME =~ *$leaf"]
    }
    if {[llength $net] == 0} {
        puts $fh "  NOT FOUND -- adjust name mapping"
        continue
    }
    puts $fh "  resolved     : $net"
    puts $fh "  ROUTE_STATUS : [get_property -quiet ROUTE_STATUS $net]"

    # Driver and loads, so each failing sink can be located in the tree.
    puts $fh "  -- driver / loads --"
    foreach p [get_pins -quiet -of_objects $net -filter {DIRECTION == OUT}] {
        puts $fh "    DRIVER $p"
    }
    foreach p [get_pins -quiet -of_objects $net -filter {DIRECTION == IN}] {
        puts $fh "    LOAD   $p"
    }

    # The key measurement: how many distinct resources leave the BRAM site.
    puts $fh "  -- nodes (physical route) --"
    set nodes [get_nodes -quiet -of_objects $net]
    puts $fh "    node count: [llength $nodes]"
    foreach nd $nodes {
        puts $fh "    node $nd"
    }

    puts $fh "  -- pips --"
    set pips [get_pips -quiet -of_objects $net]
    puts $fh "    pip count: [llength $pips]"
    foreach pip $pips {
        puts $fh "    pip  $pip"
    }
    puts $fh ""
}

close $fh
puts "wrote $out"
