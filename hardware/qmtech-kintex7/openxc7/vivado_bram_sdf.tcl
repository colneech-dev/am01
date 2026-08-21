# Extract REAL Kintex-7 block RAM timing from Vivado's speed files.
#
# WHY: prjxray ships no kintex7 timing data at all. make-bram-timing-db.sh
# works around that by extracting artix7 SDF and re-emitting it under kintex7 --
# same primitive family, different silicon, so the numbers are indicative but not
# authoritative for this part (xc7k325t-1).
#
# Vivado has the real values. write_sdf on a routed checkpoint emits them as
# structured IOPATH entries. Cell delay is a DEVICE property, not a design
# property, so it does not matter that this checkpoint came from Vivado
# synthesis and has a different netlist from our yosys one -- the RAMB18E1 arcs
# are the real silicon numbers either way.
#
# The arc that matters for us: CLK -> DOADO/DOBDO with the output register
# DISABLED (DO*_REG=0), which is what the OdoCrypt sboxes use. The artix7 proxy
# gives 2.454 ns for that; this tells us the true figure.
#
# Run:  vivado -mode batch -source vivado_bram_sdf.tcl
# Out:  vivado_bram_timing.sdf   (full SDF, grep RAMB18E1 out of it)
#       vivado_bram_summary.txt  (the arcs we care about)

set dcp ../vivado/build/am01_qmtech_kintex7.runs/impl_1/am01_qmtech_top_routed.dcp
set sdf vivado_bram_timing.sdf
set summary vivado_bram_summary.txt

if {![file exists $dcp]} {
    puts "ERROR: routed checkpoint not found: $dcp"
    exit 1
}

open_checkpoint $dcp

# Report the speed grade actually in use, so the numbers are attributable.
set part [get_property PART [current_design]]
set speed [get_property SPEED [get_parts $part]]
puts "PART=$part SPEED=$speed"

# SDF for the whole design. Slow process corner is what static timing wants.
puts "writing SDF (this takes a few minutes on a design this size)..."
write_sdf -process_corner slow -force $sdf
puts "wrote $sdf"

# Also pull the numbers directly from the timing engine, which avoids having to
# trust an SDF parser and gives a cross-check against the file.
set fh [open $summary w]
puts $fh "# Kintex-7 RAMB18E1 timing from Vivado"
puts $fh "# part=$part speed=$speed corner=slow"
puts $fh ""

set brams [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB18*}]
puts $fh "RAMB18 cells in design: [llength $brams]"
if {[llength $brams] > 0} {
    set b [lindex $brams 0]
    puts $fh "sample cell: $b"
    puts $fh "  REF_NAME    : [get_property -quiet REF_NAME $b]"
    puts $fh "  DOA_REG     : [get_property -quiet DOA_REG $b]"
    puts $fh "  DOB_REG     : [get_property -quiet DOB_REG $b]"
    puts $fh "  RAM_MODE    : [get_property -quiet RAM_MODE $b]"
    puts $fh "  READ_WIDTH_A: [get_property -quiet READ_WIDTH_A $b]"
}
puts $fh ""

# Worst CLK->DOUT arc across all BRAMs, straight from the timing engine.
puts $fh "-- worst clock-to-out paths starting at a BRAM --"
foreach dir {max min} {
    set paths [get_timing_paths -quiet -from $brams -delay_type $dir -max_paths 3 -nworst 1]
    foreach p $paths {
        puts $fh "  [$dir] slack=[get_property -quiet SLACK $p] \
datapath=[get_property -quiet DATAPATH_DELAY $p] \
startpoint=[get_property -quiet STARTPOINT_PIN $p]"
    }
}

close $fh
puts "wrote $summary"
