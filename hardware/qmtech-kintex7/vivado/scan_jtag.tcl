# List whatever JTAG hardware is attached, without programming anything.
# Run:  vivado -mode batch -source scan_jtag.tcl
open_hw_manager
connect_hw_server
set targets [get_hw_targets]
if {[llength $targets] == 0} {
    puts "NO JTAG TARGETS FOUND"
    puts "  - is a JTAG adapter plugged into J1 and into this PC?"
    puts "  - is the board powered?"
} else {
    puts "TARGETS:"
    foreach t $targets { puts "  $t" }
    open_hw_target [lindex $targets 0]
    foreach d [get_hw_devices] {
        puts "DEVICE: $d  (part [get_property PART $d])"
    }
    close_hw_target
}
disconnect_hw_server
close_hw_manager
