# T5: Vivado placement -> nextpnr routing.
#
# WHY THIS TEST
# -------------
# After correcting the isotropic heuristic and the floorplan Y-banding, openXC7
# reaches 92.36 MHz on this design with a complete route. Vivado reaches 162 MHz
# on the same part with twice the BRAMs. Two placement-scale corrections that were
# well motivated by measurement (hpwl_scale inversion; hpwl_scale_y = 1) both came
# out slightly NEGATIVE, which is consistent with the independent review's finding
# that HeAP's criticality term is ceiling-limited and cannot dominate placement
# regardless of tuning:
#
#     "the strongest a maximally-critical y-arc can pull is 11/N against 2/N for
#      every ordinary arc -- a 5.5x ceiling. A RAMB18 carries ~40 nets; 5.5x on
#      one of them is ~12% of the total force on that cell. It cannot win."
#
# So further knob-turning is hitting a structural limit. This test settles the
# remaining ambiguity in one run: give nextpnr's ROUTER a known-good placement.
#
#   near 162 MHz -> the router is fine, the placer is the whole gap, and effort
#                   belongs in placement (or in this hybrid flow)
#   still ~92 MHz -> the router's cost model matters after all, and the
#                   criticality work (CRIT_WEIGHT / SHARE_EXP / the open timing
#                   feedback loop) is worth pursuing
#
# NOT a shippable open-source flow -- it needs Vivado. Purely diagnostic.
#
# APPROACH
# --------
# Avoids RapidWright/json2dcp (json_drc-portable is not installed). yosys emits a
# structural netlist of plain Xilinx primitives, which Vivado can link and place
# directly. We then export each cell's BEL so it can be written back into the
# nextpnr JSON as a BEL attribute, which placer_heap.cc place_constraints()
# honours at STRENGTH_USER.
#
# Run:  vivado -mode batch -source vivado_place_export.tcl
# Out:  vivado_placement.txt    <cell_name> <BEL>

set nl   out_nm1_nosr/netlist_for_vivado.v
set xdc  ../xdc/qmtech_xc7k325t_pinout.xdc
set part xc7k325tffg676-1
set top  am01_qmtech_top
set out  vivado_placement.txt

if {![file exists $nl]} { puts "ERROR: no netlist at $nl"; exit 1 }

puts "== reading structural netlist =="
read_verilog $nl

puts "== linking =="
if {[catch {link_design -part $part -top $top} err]} {
    puts "ERROR: link_design failed: $err"
    exit 1
}
puts "linked: [llength [get_cells -hierarchical]] cells"

# Pin/IO constraints only. The clock constraint matters for placement quality.
if {[file exists $xdc]} {
    if {[catch {read_xdc $xdc} err]} { puts "WARNING: read_xdc: $err" }
}

puts "== placing (this is the slow part) =="
if {[catch {place_design} err]} {
    puts "ERROR: place_design failed: $err"
    exit 1
}

puts "== post-place timing =="
# Save the placed design so this expensive step never has to be repeated.
write_checkpoint -force vivado_placed_yosys.dcp

# Report PER CLOCK. A bare WNS is not interpretable on its own: it could belong
# to the 50 MHz bus domain or the 133.33 MHz hash domain, and the conclusion
# differs enormously. The first run printed only "WNS=-3.496" with no clock
# attribution, and reading ~91 MHz off that was inference, not measurement.
foreach clk [get_clocks] {
    set nm [get_property NAME $clk]
    set per [get_property PERIOD $clk]
    set tp [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 \
              -from [get_clocks $nm] -to [get_clocks $nm]]
    if {[llength $tp] == 0} {
        puts "  CLOCK $nm period $per ns : no intra-clock paths"
        continue
    }
    set s [get_property SLACK $tp]
    set ach [expr {$per - $s}]
    puts [format "  CLOCK %-18s period %7.3f ns  WNS %8.3f ns  -> %.3f ns = %.2f MHz" \
            $nm $per $s $ach [expr {1000.0 / $ach}]]
    puts "      startpoint [get_property -quiet STARTPOINT_PIN $tp]"
    puts "      endpoint   [get_property -quiet ENDPOINT_PIN $tp]"
    puts "      logic [get_property -quiet DATAPATH_LOGIC_DELAY $tp] ns  net [get_property -quiet DATAPATH_NET_DELAY $tp] ns"
}

puts "== exporting placement =="
set fh [open $out w]
set n 0
foreach c [get_cells -hierarchical -filter {IS_PRIMITIVE}] {
    set bel [get_property -quiet BEL $c]
    set loc [get_property -quiet LOC $c]
    if {$bel eq "" || $loc eq ""} { continue }
    # nextpnr wants SITE/BELNAME; Vivado gives SITE_TYPE.BELNAME in BEL and the
    # site in LOC, so recombine.
    set belname [lindex [split $bel .] end]
    puts $fh "[get_property NAME $c]\t$loc/$belname"
    incr n
}
close $fh
puts "wrote $n placed cells to $out"
