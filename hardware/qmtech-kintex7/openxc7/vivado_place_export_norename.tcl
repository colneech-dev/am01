# Place the -norename netlist in Vivado and export name + LOC + BEL for EVERY cell.
#
# SCOPE: DIAGNOSTIC ONLY -- THIS MAP CANNOT BE COMMITTED AND REUSED
# -----------------------------------------------------------------
# The exported map is keyed on yosys cell names, and those are built entirely
# from volatile counters:
#
#     $abc$493613$auto$blifparse.cc:557:parse_blif$493614
#           ^^^^^^        ^^^^^^^^^^^^^^^^^^^^^^^  ^^^^^^
#           ABC counter   yosys source file:line   autoidx
#
# Measured, not assumed. Two 8-bit modules identical except for ONE extra
# unrelated gate at the end of the file:
#
#     v1 abc-named cells : 15
#     v2 abc-named cells : 17
#     names in BOTH      :  0
#
# The ABC counter shifted 1611 -> 1613 and renamed every cell, including the 15
# whose logic was untouched. So any RTL edit, yosys upgrade or synthesis-option
# change invalidates 100% of this map -- it is a snapshot of one netlist, never a
# floorplan for future builds of this board.
#
# The net-name round index (derive_round_index.py) has lower coverage (51621 vs
# 70011) but is DURABLE: 'crypter.round14.sboxes.sbox35inst' comes from RTL
# structure, not counters, and was verified identical across files (1260 sbox
# paths, all matching). That is the mechanism to commit.
#
# Use this export to LEARN the geometry -- where each round actually belongs and
# how large its box should be, taken from a placement that meets timing -- then
# encode that geometry in the durable net-name script. Vivado teaches the
# floorplan; the net-name script ships it.
#
# Safety: check_placement_names.py refuses below a 90% match rate. Since a changed
# netlist scores ~0% rather than 89%, a stale map fails loudly instead of
# half-applying, which would be far more dangerous.
#
# WHY THE NET-NAME HEURISTIC IS NOT ENOUGH ON ITS OWN
# ---------------------------------------------------
# derive_round_index.py recovers a round index for 51621 of 71632 cells by parsing
# NET names, then preplace_round_regions.py invents a bounding box per round. Both
# steps are inference. This is measurement: Vivado's own placement gives an exact
# site for all 70011 primitives, taken from a run that reached 158.81 MHz with 0
# unrouted nets.
#
# It also settles what the heuristic cannot. Sampling the 18354 cells the
# heuristic could not resolve shows they are mostly NOT round logic at all:
#
#     LUT2   odocrypt_gpio_wrapper_inst.req_sync2_h
#     LUT3   odocrypt_gpio_wrapper_inst.addr_latched
#     LUT6   odocrypt_gpio_wrapper_inst.hash_active_bus
#     LUT5   $auto$alumacc.cc:512:replace_alu$58344.Y     (the nonce adder)
#
# GPIO wrapper, control, and the adder. Neighbour propagation would have assigned
# 52% of them a round anyway -- and a comparator reading round 20's output is not
# round-20 logic. That is the same failure as the round-0 contamination (one
# global signal sweeping 8786 cells into round 0), just harder to spot. Vivado's
# placement needs no such guess.
#
# WHY -norename MATTERS HERE
# --------------------------
# vivado_placed_yosys.dcp already exists but was built from the DEFAULT
# write_verilog output, whose cells are named '_62672_'. Those names join to
# nothing in the nextpnr JSON, which is why the first "nextpnr place -> Vivado
# route" attempt applied 0 of 141548 constraints. netlist_norename.v preserves the
# yosys names, and Vivado round-trips them intact -- verified: 70011 cells dumped,
# 98.74% of them matched against a nextpnr placement.
#
# TWO USES
# --------
#   1. Vivado placement -> nextpnr router. The T5 experiment as originally
#      intended, isolating the router. Its complement (nextpnr place -> Vivado
#      route) is unblocked but has never been run with a working name map.
#   2. A floorplan with 100% coverage, derived from a placement known to meet
#      timing, instead of 420 BRAMs (0.6%) and invented boxes.
#
# Run:  vivado -mode batch -source vivado_place_export_norename.tcl
# Out:  vivado_placement_norename.txt    <cell>\t<LOC>\t<BEL>\t<REF_NAME>
#       vivado_placed_norename.dcp

set nl   out_nm1_nosr/netlist_norename.v
set xdc  ../xdc/qmtech_xc7k325t_pinout.xdc
set part xc7k325tffg676-1
set top  am01_qmtech_top
set out  vivado_placement_norename.txt

if {![file exists $nl]} {
    puts "ERROR: no netlist at $nl -- run 'yosys -s make_vivado_netlist.ys' first"
    exit 1
}

puts "== reading $nl =="
if {[catch {read_verilog $nl} err]} { puts "ERROR: read_verilog: $err"; exit 1 }

puts "== linking =="
if {[catch {link_design -part $part -top $top} err]} {
    puts "ERROR: link_design: $err"; exit 1
}
puts "linked [llength [get_cells -hierarchical -filter {IS_PRIMITIVE}]] primitive cells"

if {[file exists $xdc]} {
    if {[catch {read_xdc $xdc} err]} { puts "WARNING: read_xdc: $err" }
}

puts "== placing =="
if {[catch {place_design} err]} { puts "ERROR: place_design: $err"; exit 1 }
write_checkpoint -force vivado_placed_norename.dcp

# Report per clock. A bare WNS is not interpretable: it could belong to the 50 MHz
# bus domain or the 133.33 MHz hash domain and the conclusion differs enormously.
# An earlier run printed only "WNS=-3.496" with no clock attribution, and reading
# ~91 MHz off it was inference that turned out to be wrong by a factor of two.
puts "== post-place timing =="
foreach clk [get_clocks] {
    set nm [get_property NAME $clk]
    set per [get_property PERIOD $clk]
    set tp [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 \
              -from [get_clocks $nm] -to [get_clocks $nm]]
    if {[llength $tp] == 0} { puts "  CLOCK $nm period $per : no intra-clock paths"; continue }
    set s [get_property SLACK $tp]
    set ach [expr {$per - $s}]
    puts [format "  CLOCK %-34s period %7.3f  WNS %8.3f  -> %.3f ns = %.2f MHz" \
            $nm $per $s $ach [expr {1000.0 / $ach}]]
    puts "      logic [get_property -quiet DATAPATH_LOGIC_DELAY $tp] ns  net [get_property -quiet DATAPATH_NET_DELAY $tp] ns"
}

puts "== exporting placement =="
set fh [open $out w]
set n 0
set unplaced 0
foreach c [get_cells -hierarchical -filter {IS_PRIMITIVE}] {
    set bel [get_property -quiet BEL $c]
    set loc [get_property -quiet LOC $c]
    if {$bel eq "" || $loc eq ""} { incr unplaced; continue }
    # nextpnr wants SITE/BELNAME. Vivado splits this: LOC holds the site, BEL
    # holds SITE_TYPE.BELNAME -- so take the last component of BEL and recombine.
    set belname [lindex [split $bel .] end]
    puts $fh "[get_property NAME $c]\t$loc\t$belname\t[get_property REF_NAME $c]"
    incr n
}
close $fh
puts "wrote $n placed cells to $out ($unplaced had no LOC/BEL)"
