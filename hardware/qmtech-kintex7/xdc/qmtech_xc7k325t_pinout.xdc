#  AtomMiner AM01 -- QMTECH Kintex-7 (XC7K325T) + Raspberry Pi CM4 variant
#  Copyright 2015-2022 AtomMiner <atom@atomminer.com>
#
# This code is free software; you can redistribute it and/or modify it
# under the terms of the BSD 3-Clause License as published by the Free
# Software Foundation; See COPYING for more details.
#
# Reference pin assignments for the QMTECH XC7K325T dev board (chip:
# XC7K325T-1FFG676C), transcribed from "QMTECH XC7K325T DEV BOARD USER
# MANUAL V01". See ../README.md for the bus protocol these pins carry.
#
# STATUS: not verified on real hardware (nobody has flashed this board
# yet), BUT every ball name and every bank voltage below has now been
# checked against authoritative machine-readable sources rather than a
# manual transcription:
#
#  1. BALL NAMES: all 30 PACKAGE_PINs in this file were checked to exist
#     on this exact package, using prjxray-db's package_pins.csv for
#     xc7k325tffg676-1 (openXC7's fork, which is generated from the
#     vendor tooling's own part data). All 30 resolve to real IOB sites.
#     A ball that doesn't exist on the package is a hard error in both
#     Vivado and nextpnr-xilinx ("device does not have a pin named X"),
#     so this check is worth re-running after any edit:
#       awk -F',' 'NR>1{print $1","$2}' package_pins.csv
#
#  2. BANK VOLTAGES: read off the vendor's own schematic
#     (QMTECH-XC7K325T-DEVELOPMENT-BOARD_SCHEMATIC_20231120_V01.pdf,
#     sheet 4, the U11Q VCCO block) instead of assuming the manual's
#     "default 3.3V":
#       banks 0, 13, 14, 15, 16 -> 3V3      (one shared 3V3 rail)
#       bank  12                -> VCCO_12, itself tied to 3V3 via the
#                                  0R links R31/R32 (sheet 4 power)
#       banks 32, 33            -> 1V8
#       bank  34                -> 1V5
#     The CM4 GPIO bus balls below all land in banks 15 and 16, and the
#     LEDs/keys in banks 12 and 13 -- i.e. every signal this file
#     constrains is on a 3.3V bank, so LVCMOS33 throughout is correct.
#     (This resolves the "verify the GPIO bank/voltage" item that
#     ../README.md lists under "what's still needed".) 1V8/1V5 banks 32,
#     33 and 34 carry the DDR3 interface, which this file doesn't touch.

set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]

# ---------------------------------------------------------------------
# System clock: on-board 50MHz crystal. Net name in the QMTECH schematic
# is "SYS_CLK_F22" -- ball F22 by the schematic's own naming convention.
# ---------------------------------------------------------------------
set_property PACKAGE_PIN F22 [get_ports sys_clk_50m]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk_50m]
create_clock -period 20.000 -name sys_clk_50m [get_ports sys_clk_50m]

# ---------------------------------------------------------------------
# GPIO parallel bus to the Raspberry Pi CM4 socket (see README.md for
# the protocol). 24 of the 28 available CM4<->FPGA GPIO lines are used.
# ---------------------------------------------------------------------

# DATA[15:0] = CM4 GPIO0..15
set_property PACKAGE_PIN C12 [get_ports {gpio_data[0]}]
set_property PACKAGE_PIN B11 [get_ports {gpio_data[1]}]
set_property PACKAGE_PIN C18 [get_ports {gpio_data[2]}]
set_property PACKAGE_PIN D18 [get_ports {gpio_data[3]}]
set_property PACKAGE_PIN E18 [get_ports {gpio_data[4]}]
set_property PACKAGE_PIN C11 [get_ports {gpio_data[5]}]
set_property PACKAGE_PIN D10 [get_ports {gpio_data[6]}]
set_property PACKAGE_PIN B12 [get_ports {gpio_data[7]}]
set_property PACKAGE_PIN A12 [get_ports {gpio_data[8]}]
set_property PACKAGE_PIN D14 [get_ports {gpio_data[9]}]
set_property PACKAGE_PIN C13 [get_ports {gpio_data[10]}]
set_property PACKAGE_PIN D13 [get_ports {gpio_data[11]}]
set_property PACKAGE_PIN A10 [get_ports {gpio_data[12]}]
set_property PACKAGE_PIN E10 [get_ports {gpio_data[13]}]
set_property PACKAGE_PIN C17 [get_ports {gpio_data[14]}]
set_property PACKAGE_PIN A15 [get_ports {gpio_data[15]}]

# ADDR[3:0] = CM4 GPIO16..19
set_property PACKAGE_PIN B10 [get_ports {gpio_addr[0]}]
set_property PACKAGE_PIN D16 [get_ports {gpio_addr[1]}]
set_property PACKAGE_PIN B15 [get_ports {gpio_addr[2]}]
set_property PACKAGE_PIN B9  [get_ports {gpio_addr[3]}]

# Control lines = CM4 GPIO20..23
set_property PACKAGE_PIN A9  [get_ports gpio_wr_n]
set_property PACKAGE_PIN A8  [get_ports gpio_rd_n]
set_property PACKAGE_PIN C14 [get_ports gpio_ready]
set_property PACKAGE_PIN A14 [get_ports gpio_irq]

# Reserved / spare = CM4 GPIO24..27 (not instantiated in the top-level yet)
# GPIO24 -> B14
# GPIO25 -> A13
# GPIO26 -> C9
# GPIO27 -> D15

set_property IOSTANDARD LVCMOS33 [get_ports {gpio_data[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_addr[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports gpio_wr_n]
set_property IOSTANDARD LVCMOS33 [get_ports gpio_rd_n]
set_property IOSTANDARD LVCMOS33 [get_ports gpio_ready]
set_property IOSTANDARD LVCMOS33 [get_ports gpio_irq]

set_property SLEW SLOW [get_ports {gpio_data[*]}]
set_property SLEW SLOW [get_ports gpio_ready]
set_property SLEW SLOW [get_ports gpio_irq]

# ---------------------------------------------------------------------
# On-board user LEDs / keys (per the manual's tables in 2.2.6 / 2.2.7),
# useful for bring-up/status while porting -- optional in the top level.
# ---------------------------------------------------------------------
set_property PACKAGE_PIN R26 [get_ports {status_led[0]}]
set_property PACKAGE_PIN P26 [get_ports {status_led[1]}]
set_property PACKAGE_PIN N26 [get_ports {status_led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {status_led[*]}]

set_property PACKAGE_PIN V26 [get_ports user_key_sw2]
set_property PACKAGE_PIN U26 [get_ports user_key_sw3]
# SW2/SW3 are 3.3V, verified against the vendor's own schematic
# (QMTECH-XC7K325T-DEVELOPMENT-BOARD_SCHEMATIC_20231120_V01.pdf in
# ChinaQMTECH/QMTECH_Kintex-7_Development_Board), NOT a manual excerpt:
#   - Sheet 2: SW2/SW3 pull-ups R17/R18 (4.7K) go to the **VCCO_12** net.
#   - Sheet 4 (power): VCCO_12 is tied to the **3V3** rail through R31 and
#     R32, two parallel 0R links off the TPS563201 buck's L4 output.
#   - Both balls are in **bank 12** (per prjxray-db's package_pins.csv for
#     xc7k325tffg676-1: U26 = IOB_X0Y42, V26 = IOB_X0Y41, bank 12), and
#     bank 12's VCCO *is* that VCCO_12 rail.
# So the bank supply and the pull-up rail are the same 3.3V net -- both
# reasons independently rule out LVCMOS18. An earlier revision of this
# file set these to LVCMOS18 based on a misreading of the manual; that
# was wrong and is corrected here. (A 1.8V standard declared on a
# 3.3V-powered bank is a DRC error in Vivado, and a reliability problem
# if forced through.)
set_property IOSTANDARD LVCMOS33 [get_ports user_key_sw2]
set_property IOSTANDARD LVCMOS33 [get_ports user_key_sw3]

# JTAG (TCK/TDO/TDI/TMS) and PROGRAM_B/DONE/INIT_B are dedicated
# configuration pins on this device/package -- Vivado handles them
# automatically; no PACKAGE_PIN constraints needed here.
