# Dump the cell names Vivado ACTUALLY has after linking the netlist.
#
# WHY THIS EXISTS
# ---------------
# The first "nextpnr place -> Vivado route" attempt applied 0 / 141548
# constraints. I had guessed at how yosys names survive read_verilog (and guessed
# wrong twice: assumed packing was the issue, and applied a '.' -> '/' hierarchy
# substitution that corrupted auto-generated names embedding source paths, e.g.
# 'miner.v:47' became 'miner/v:47').
#
# Rather than guess a third time, this dumps ground truth. check_placement_names.py
# then diffs it against the nextpnr JSON and reports a match rate BEFORE anyone
# spends an hour on route_design.
#
# Run:  vivado -mode batch -source vivado_dump_cellnames.tcl
# Out:  vivado_cellnames.txt     <name>\t<ref_name>

set nl   out_nm1_nosr/netlist_norename.v
set part xc7k325tffg676-1
set top  am01_qmtech_top
set out  vivado_cellnames.txt

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

set cells [get_cells -hierarchical -filter {IS_PRIMITIVE}]
puts "linked [llength $cells] primitive cells"

set fh [open $out w]
foreach c $cells {
    puts $fh "[get_property NAME $c]\t[get_property REF_NAME $c]"
}
close $fh
puts "wrote [llength $cells] cell names to $out"
