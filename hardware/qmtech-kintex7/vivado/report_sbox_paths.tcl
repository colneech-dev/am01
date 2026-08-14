#  AtomMiner AM01 -- QMTECH Kintex-7 + Raspberry Pi CM4 variant
#  Copyright 2015-2022 AtomMiner <atom@atomminer.com>
#
# This code is free software; you can redistribute it and/or modify it
# under the terms of the BSD 3-Clause License as published by the Free
# Software Foundation; See COPYING for more details.
#
# report_sbox_paths.tcl -- is the hash core routing-bound on the S-box
# address path?
#
# WHY
# ---
# encrypt_4apply_pbox0 is 640 plain wire assignments: the S-box address is
# a pure permutation of state[i], a flip-flop output, at ZERO logic levels.
# Yet sbox_large_mux2.v measures that address settling ~9.6 ns into an
# 11.78 ns clk_h period -- 82% of the clock on a path with no logic in it.
# If that is right, the design's Fmax is set by placement, not by the
# fabric, and there is no floorplanning anywhere in this build to fix it.
#
# This script measures it. For each unrolled encrypt round it reports:
#   * where that round's 20 block RAMs were placed (bounding box)
#   * where that round's 640 state registers were placed (bounding box)
#   * the worst state[i] -> block-RAM-address delay
#
# A large spread plus a large delay confirms the diagnosis; a tight spread
# with a large delay refutes it and points back at the fabric.
#
# Usage (after synthesis + placement, in an open design):
#   vivado -mode batch -source build.tcl
#   # ... launch_runs impl_1 ...
#   open_run impl_1
#   source report_sbox_paths.tcl
#
# Or against a checkpoint:
#   vivado -mode batch -source report_sbox_paths.tcl -tclargs post_place.dcp

if {$argc > 0} {
    set dcp [lindex $argv 0]
    puts "Opening checkpoint: $dcp"
    open_checkpoint $dcp
}

# Site name -> {X Y}, e.g. RAMB18_X4Y30 or SLICE_X12Y88
proc site_xy {loc} {
    if {[regexp {X(\d+)Y(\d+)} $loc -> x y]} { return [list $x $y] }
    return {}
}

# Bounding box of a cell collection, as {xmin xmax ymin ymax placed_count}
proc bbox {cells} {
    set xs {} ; set ys {}
    foreach c $cells {
        set loc [get_property -quiet LOC $c]
        if {$loc eq ""} { continue }
        set xy [site_xy $loc]
        if {[llength $xy] != 2} { continue }
        lappend xs [lindex $xy 0]
        lappend ys [lindex $xy 1]
    }
    if {[llength $xs] == 0} { return {} }
    set xs [lsort -integer $xs] ; set ys [lsort -integer $ys]
    return [list [lindex $xs 0] [lindex $xs end] \
                 [lindex $ys 0] [lindex $ys end] [llength $xs]]
}

# Every encrypt loop in the design -- one per miner instance.
set loops [get_cells -hier -filter {REF_NAME =~ "encrypt_*encrypt_loop"}]
if {[llength $loops] == 0} {
    puts "ERROR: no encrypt_*encrypt_loop instances found."
    puts "       Is a synthesised/placed design open?"
    return
}

puts ""
puts "=============================================================================="
puts " S-box address path -- placement spread and delay, per unrolled encrypt round"
puts "=============================================================================="

foreach loop $loops {
    puts ""
    puts "instance: $loop"
    puts [format "  %-6s %-22s %-22s %10s" "round" "BRAM bbox (X,Y)" "state reg bbox (X,Y)" "worst ns"]
    puts "  [string repeat - 70]"

    # Rounds are named round0..roundN inside the loop.
    set rounds [lsort -dictionary [get_cells -quiet $loop/round*]]
    foreach r $rounds {
        if {![regexp {round(\d+)$} $r -> n]} { continue }

        set brams [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ BMEM.*.*} \
                       -of_objects [get_cells -quiet $r]]
        if {[llength $brams] == 0} {
            set brams [get_cells -quiet -hier -filter {REF_NAME =~ RAMB*} \
                           -of_objects [get_cells -quiet $r]]
        }
        set sregs [get_cells -quiet "$loop/state_reg\[$n\]\[*\]"]

        set bb [bbox $brams]
        set sb [bbox $sregs]
        set bbs "n/a" ; set sbs "n/a"
        if {[llength $bb] == 5} {
            set bbs [format "%d-%d, %d-%d (%d)" [lindex $bb 0] [lindex $bb 1] \
                         [lindex $bb 2] [lindex $bb 3] [lindex $bb 4]]
        }
        if {[llength $sb] == 5} {
            set sbs [format "%d-%d, %d-%d (%d)" [lindex $sb 0] [lindex $sb 1] \
                         [lindex $sb 2] [lindex $sb 3] [lindex $sb 4]]
        }

        # Worst state[n] -> this round's block RAM path.
        set ns "-"
        if {[llength $sregs] > 0 && [llength $brams] > 0} {
            set paths [get_timing_paths -quiet -from $sregs -to $brams \
                           -max_paths 1 -nworst 1 -delay_type max]
            if {[llength $paths] > 0} {
                set d [get_property -quiet DATAPATH_DELAY [lindex $paths 0]]
                if {$d ne ""} { set ns [format "%.3f" $d] }
            }
        }
        puts [format "  %-6s %-22s %-22s %10s" $n $bbs $sbs $ns]
    }
}

puts ""
puts "Interpretation:"
puts "  Wide bounding boxes + large delay -> placement-bound. Floorplan each"
puts "     round (its 20 block RAMs + its 640 state registers) into a pblock."
puts "  Tight bounding boxes + large delay -> not placement. Look at the fabric"
puts "     and at block RAM setup time instead."
puts ""

# Overall worst path into any block RAM address pin, for reference.
puts "Worst path into any block RAM (whole design):"
report_timing -quiet -to [get_pins -quiet -hier -filter {REF_PIN_NAME =~ ADDR*}] \
              -max_paths 5 -nworst 1 -delay_type max -sort_by slack
