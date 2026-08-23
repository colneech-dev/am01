# nextpnr PLACEMENT -> Vivado ROUTER, with the SRL cells left free.
#
# WHY THE SRLs ARE EXCLUDED
# -------------------------
# The first attempt applied 136580 / 136636 constraints (100.0%) and then died
# in Vivado's PLACER, not on name mapping:
#
#   ERROR: [Place 30-484] The packing of LUTRAM/SRL instances into capable
#          slices could not be obeyed.
#          Number of LUTRAMs/SRLs: 2
#          Number of capable slices required is 6 out of 16000
#   ERROR: [Place 30-99] Placer failed with error: 'Could not place all lutrams'
#
# nextpnr packs four SRLC32E into SLICE_X2Y137 (A6/B6/C6/D6LUT). That site IS a
# SLICEM -- checked against prjxray tilegrid, so the site type is not the
# problem -- but Vivado's LUTRAM/SRL packer wants six slices for them and will
# not accept the denser packing.
#
# An earlier version of this script tried to HAND-PLACE the two failing cells at
# SLICE_X2Y137. That was backwards: it pinned them to precisely the site Vivado
# had already rejected, so it could only fail the same way.
#
# Leaving 12 constraint lines (6 cells) unpinned out of 136636 is a rounding
# error against the 56 that already fail, and it lets Vivado's packer choose a
# legal SRL arrangement while every other cell stays where nextpnr put it.
#
# The constraint loop and the timing report are lifted verbatim from
# vivado_route_nextpnr_placement.tcl and vivado_route_own_placement.tcl
# respectively -- both are proven on this design. A previous rewrite of the loop
# used `uplevel 1` instead of `eval` and dropped the comment skip, which failed
# every single line.
#
# Run:  vivado -mode batch -source vivado_route_nextpnr_handplaced.tcl
# Out:  vivado_route_nextpnr_handplaced.txt

set nl    out_nm1_nosr/netlist_norename_v68.v
set plxdc out_nm1_nosr/nextpnr_placement_v68.xdc
set part  xc7k325tffg676-1
set top   am01_qmtech_top
set out   vivado_route_nextpnr_handplaced.txt
set min_applied_frac 0.99

foreach f [list $nl $plxdc] {
    if {![file exists $f]} { puts "ERROR: missing $f"; exit 1 }
}

puts "== reading $nl =="
if {[catch {read_verilog $nl} err]} { puts "ERROR: read_verilog: $err"; exit 1 }

puts "== linking =="
if {[catch {link_design -part $part -top $top} err]} {
    puts "ERROR: link_design: $err"; exit 1
}

# Apply the placement constraint-by-constraint so failures are countable, and
# skip the SRL cells so Vivado's packer can place them itself.
puts "== applying nextpnr placement (SRLs excluded) =="
set applied 0
set failed 0
set skipped_srl 0
set fails_shown 0
set fh [open $plxdc r]
while {[gets $fh line] >= 0} {
    if {[string match "#*" $line] || [string trim $line] eq ""} { continue }
    if {[string match "*fpga_srl*" $line]} { incr skipped_srl; continue }
    if {[catch {eval $line} err]} {
        incr failed
        if {$fails_shown < 5} { puts "  FAIL: $line -> $err"; incr fails_shown }
    } else {
        incr applied
    }
}
close $fh
set total [expr {$applied + $failed}]
set frac [expr {$total > 0 ? double($applied) / $total : 0}]
puts [format "applied %d / %d (%.1f%%), failed %d, skipped %d SRL lines" \
        $applied $total [expr {$frac * 100}] $failed $skipped_srl]

if {$frac < $min_applied_frac} {
    puts "ERROR: only [format %.1f [expr {$frac*100}]]% of placement constraints applied."
    puts "       Vivado would be routing a DIFFERENT placement from nextpnr's, so the"
    puts "       comparison would be meaningless. Aborting rather than reporting a"
    puts "       plausible-looking number."
    exit 1
}

puts "== place (near-trivial: almost every cell is fixed) =="
if {[catch {place_design} err]} { puts "ERROR: place_design: $err"; exit 1 }

# Independent check that the placement really is nextpnr's. Without this there
# is no way to tell a constrained run from a free one after the fact, and a free
# Vivado placement would report a plausible number for the wrong experiment.
set fixed [llength [get_cells -quiet -hierarchical -filter {IS_LOC_FIXED}]]
puts "post-place: $fixed cells are LOC-fixed"

puts "== route =="
if {[catch {route_design} err]} { puts "ERROR: route_design: $err"; exit 1 }

write_checkpoint -force vivado_routed_nextpnr_placement.dcp

puts "== post-route timing =="
set fh2 [open $out w]
puts $fh2 "# Vivado ROUTER on nextpnr PLACEMENT (SRL cells left free)"
puts $fh2 "# constraints applied: $applied / $total, skipped $skipped_srl SRL lines"
puts $fh2 "# LOC-fixed cells after place_design: $fixed"
foreach clk [get_clocks] {
    set nm  [get_property NAME $clk]
    set per [get_property PERIOD $clk]
    set tp [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 \
              -from [get_clocks $nm] -to [get_clocks $nm]]
    if {[llength $tp] == 0} { puts $fh2 "  $nm: no intra-clock paths"; continue }
    set s   [get_property SLACK $tp]
    set ach [expr {$per - $s}]
    set line [format "  CLOCK %-34s period %7.3f  WNS %8.3f  -> %.3f ns = %.2f MHz" \
                $nm $per $s $ach [expr {1000.0 / $ach}]]
    puts $fh2 $line
    puts $line
    set l "      logic [get_property -quiet DATAPATH_LOGIC_DELAY $tp] ns  net [get_property -quiet DATAPATH_NET_DELAY $tp] ns"
    puts $fh2 $l
    puts $l
}

# Routing completeness. Use Vivado's own reporter, not a hand-rolled
# ROUTE_STATUS filter -- that over-reports badly on benign statuses.
puts $fh2 ""
set rs [report_route_status -return_string]
foreach ln [split $rs "\n"] {
    if {[string match "*Unrouted Nets*" $ln] || [string match "*Node Overlaps*" $ln]} {
        puts $fh2 "  [string trim $ln]"
        puts "  [string trim $ln]"
    }
}
close $fh2
puts "wrote $out"
