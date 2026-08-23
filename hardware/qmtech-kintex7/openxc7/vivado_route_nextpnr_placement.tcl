# nextpnr PLACEMENT -> Vivado ROUTER.
#
# The complement to vivado_place_export.tcl. Together they decompose the gap:
#
#     Vivado place  + nextpnr route   -> isolates the PLACER
#     nextpnr place + Vivado route    -> isolates the ROUTER   <-- this
#
# Measured so far (xc7k325t, OdoCrypt miner, NUM_MINERS=1):
#     yosys netlist + nextpnr place&route     92.36 MHz, 0 unrouted
#     yosys netlist + Vivado place            ~91 MHz (re-verifying)
#     Vivado netlist + Vivado place&route     162 MHz (own synthesis, NUM_MINERS=2)
#
# If Vivado's router on nextpnr's placement also lands near 92, neither nextpnr
# component is the bottleneck and the NETLIST sets the ceiling.
#
# VALIDITY GATE
# -------------
# nextpnr packs cells, so its cell set is not identical to the yosys netlist's.
# If a large fraction of the LOC/BEL constraints fail to resolve, Vivado is
# routing a DIFFERENT placement and the comparison is meaningless. This script
# therefore COUNTS applied vs failed constraints and refuses to continue below a
# threshold, rather than silently producing a plausible-looking number.
#
# Run:  vivado -mode batch -source vivado_route_nextpnr_placement.tcl
# Out:  vivado_route_nextpnr.txt

set nl     out_nm1_nosr/netlist_norename_v68.v
set pinxdc ../xdc/qmtech_xc7k325t_pinout.xdc
set plxdc  out_nm1_nosr/nextpnr_placement_v68.xdc
set part   xc7k325tffg676-1
set top    am01_qmtech_top
set out    vivado_route_nextpnr.txt
set min_applied_frac 0.90

foreach f [list $nl $plxdc] {
    if {![file exists $f]} { puts "ERROR: missing $f"; exit 1 }
}

puts "== link =="
read_verilog $nl
if {[catch {link_design -part $part -top $top} err]} {
    puts "ERROR: link_design: $err"; exit 1
}
puts "linked [llength [get_cells -hierarchical]] cells"

if {[file exists $pinxdc]} { catch {read_xdc $pinxdc} }

# Apply the placement constraint-by-constraint so failures are countable.
puts "== applying nextpnr placement =="
set applied 0
set failed 0
set fails_shown 0
set fh [open $plxdc r]
while {[gets $fh line] >= 0} {
    if {[string match "#*" $line] || [string trim $line] eq ""} { continue }
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
puts [format "applied %d / %d (%.1f%%), failed %d" $applied $total [expr {$frac * 100}] $failed]

if {$frac < $min_applied_frac} {
    puts "ERROR: only [format %.1f [expr {$frac*100}]]% of placement constraints applied."
    puts "       Vivado would be routing a DIFFERENT placement from nextpnr's, so the"
    puts "       comparison would be meaningless. Aborting rather than reporting a"
    puts "       plausible-looking number."
    exit 1
}

puts "== place (should be near-trivial: cells are fixed) =="
if {[catch {place_design} err]} { puts "ERROR: place_design: $err"; exit 1 }

puts "== route =="
if {[catch {route_design} err]} { puts "ERROR: route_design: $err"; exit 1 }

puts "== timing =="
set fh2 [open $out w]
puts $fh2 "# Vivado ROUTER on nextpnr PLACEMENT"
puts $fh2 "# placement constraints applied: $applied / $total"
foreach clk [get_clocks] {
    set nm [get_property NAME $clk]
    set per [get_property PERIOD $clk]
    set tp [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 \
              -from [get_clocks $nm] -to [get_clocks $nm]]
    if {[llength $tp] == 0} { puts $fh2 "  $nm: no intra-clock paths"; continue }
    set s [get_property SLACK $tp]
    set ach [expr {$per - $s}]
    set line [format "  CLOCK %-18s period %7.3f  WNS %8.3f  -> %.3f ns = %.2f MHz" \
                $nm $per $s $ach [expr {1000.0 / $ach}]]
    puts $fh2 $line
    puts $line
    puts $fh2 "      logic [get_property -quiet DATAPATH_LOGIC_DELAY $tp] ns  net [get_property -quiet DATAPATH_NET_DELAY $tp] ns"
}
close $fh2
puts "wrote $out"
