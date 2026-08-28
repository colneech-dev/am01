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

# WARNING -- this constraint does NOT reach nextpnr/openXC7.
#
# xilinx/xdc.cc attaches a create_clock to the net found by
# getNetByAlias(<port name>), i.e. literally the net "sys_clk_50m". The nets that
# actually carry clocks in this design are bus_clk and clk_h, and nothing
# propagates clkconstr through the IBUF/BUFG insertion. common/timing.cc then
# finds no clkconstr on the net at each FF clock pin and falls back to
# ctx->setting("target_freq") -- which is whatever --freq was passed.
#
# Verified in the P&R log: bus_clk IS the 50 MHz crystal, and it is reported
# "PASS at 133.33 MHz" -- i.e. checked against --freq, not against this 20 ns.
#
# Consequence: under openXC7, --freq is the ONLY timing constraint, and it is
# applied to EVERY domain. build.sh therefore refuses to run without FREQ set.
# Under Vivado this constraint works normally.

# ---------------------------------------------------------------------
# CDC: sys_clk_50m (bus_clk, used raw -- see am01_qmtech_top.v) and
# clk_h (clkout1_unbuf, the MMCM's CLKOUT1 -- see clk_gen_hash.v) come
# off the same MMCM but at a non-integer ratio (50 : 133.33) with no
# fixed phase relationship as seen from the bus side. Every signal that
# crosses between them in odocrypt_gpio_wrapper.v already goes through a
# real two-flop/toggle synchronizer (wr_n_sync/rd_n_sync, the
# req_toggle_bus<->ack_toggle_h handshake, nonce_toggle_h, etc.) -- that
# was always the design intent, not an oversight.
#
# Without this, Vivado's default STA times paths between the two clocks
# as if they were synchronous, since it has no way to know a
# synchronizer sits in between. First real build (2026-08-15) came back
# "Timing constraints are not met": intra-clock WNS was clean on both
# domains individually (clkout1_unbuf: +0.304ns; sys_clk_50m positive),
# but the *inter*-clock paths reported -3.578ns / -1.858ns WNS -- the
# synchronizer chains being timed as bogus single-clock paths. This
# constraint tells Vivado those two clocks are intentionally
# asynchronous, which is what the synchronizers are there for. See also
# the ASYNC_REG attributes on the first-stage synchronizer flops in
# odocrypt_gpio_wrapper.v (placement-side half of the same fix).
# NOTE: VIVADO ONLY. nextpnr's XDC parser (xilinx/xdc.cc) understands exactly
# three commands -- set_property, create_clock, set_multicycle_path -- and
# everything else is discarded with a log_info("ignoring unsupported XDC
# command"), i.e. at INFO level, not a warning. set_clock_groups is dropped.
#
# Under openXC7 the two domains are therefore still timed against each other.
# That direction is CONSERVATIVE (paths get timed rather than ignored), so it is
# not a correctness risk -- but do not add a set_false_path here expecting it to
# take effect, and do not read an openXC7 inter-clock number as meaningful.
#
# The same applies to the ASYNC_REG attributes on the first-stage synchroniser
# flops in odocrypt_gpio_wrapper.v: the string ASYNC_REG does not appear anywhere
# in nextpnr's xilinx backend, so it has no effect on openXC7 placement. The
# synchroniser stages can land arbitrarily far apart, degrading MTBF. If that
# matters, constrain them with explicit BEL/LOC attributes instead.
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk_50m] \
    -group [get_clocks -of_objects [get_pins clk_gen_hash_inst/mmcm_inst/CLKOUT1]]

# ---------------------------------------------------------------------
# Pull-ups on the CM4 handshake strobes.
#
# gpio_wr_n and gpio_rd_n are active-low and driven by the CM4. Between FPGA
# configuration and the CM4 configuring its GPIOs as outputs, both float. In
# odocrypt_gpio_wrapper.v, wr_active = wr_sync[2] & wr_sync[1] -- two consecutive
# samples of a floating input are enough to fire a bogus write, and a spurious
# write can shift the header shift register (odo_block_data has no word counter
# and no position reset), after which the miner runs and every result is wrong.
#
# Every IOB in the current bitstream carries PULLTYPE.NONE, so nothing holds
# these high today. Board-level pull-ups would be better on a respin; this is the
# free half of the fix.
set_property PULLUP true [get_ports gpio_wr_n]
set_property PULLUP true [get_ports gpio_rd_n]

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
# addr[4] = GPIO24 -> FPGA ball B14 (manual section 2.2.9). Already routed to
# fabric and unused by the bus, so this widens the register space from 16 to
# 32 slots without any new wiring. Needed because all 16 original slots were
# allocated once the XADC and fan registers were added.
set_property PACKAGE_PIN B14 [get_ports {gpio_addr[4]}]

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

# NOTE: bus bits are written out one per line rather than with a
# `[get_ports {foo[*]}]` wildcard. Vivado expands that wildcard fine, but
# **nextpnr-xilinx's XDC parser does not** -- it silently matches nothing,
# and the run then dies much later with the misleading
#   ERROR: port gpio_addr[0] of type PAD has no IOSTANDARD property
# Explicit per-bit lines work identically in Vivado and keep the
# openXC7 flow (see ../openxc7/) working. Same reason for status_led
# below. Don't "tidy" these back into wildcards.
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_data[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_data[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_data[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_data[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_data[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_data[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_data[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_data[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_data[8]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_data[9]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_data[10]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_data[11]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_data[12]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_data[13]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_data[14]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_data[15]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_addr[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_addr[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_addr[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_addr[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_addr[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports gpio_wr_n]
set_property IOSTANDARD LVCMOS33 [get_ports gpio_rd_n]
set_property IOSTANDARD LVCMOS33 [get_ports gpio_ready]
set_property IOSTANDARD LVCMOS33 [get_ports gpio_irq]

set_property SLEW SLOW [get_ports {gpio_data[0]}]
set_property SLEW SLOW [get_ports {gpio_data[1]}]
set_property SLEW SLOW [get_ports {gpio_data[2]}]
set_property SLEW SLOW [get_ports {gpio_data[3]}]
set_property SLEW SLOW [get_ports {gpio_data[4]}]
set_property SLEW SLOW [get_ports {gpio_data[5]}]
set_property SLEW SLOW [get_ports {gpio_data[6]}]
set_property SLEW SLOW [get_ports {gpio_data[7]}]
set_property SLEW SLOW [get_ports {gpio_data[8]}]
set_property SLEW SLOW [get_ports {gpio_data[9]}]
set_property SLEW SLOW [get_ports {gpio_data[10]}]
set_property SLEW SLOW [get_ports {gpio_data[11]}]
set_property SLEW SLOW [get_ports {gpio_data[12]}]
set_property SLEW SLOW [get_ports {gpio_data[13]}]
set_property SLEW SLOW [get_ports {gpio_data[14]}]
set_property SLEW SLOW [get_ports {gpio_data[15]}]
set_property SLEW SLOW [get_ports gpio_ready]
set_property SLEW SLOW [get_ports gpio_irq]

# ---------------------------------------------------------------------
# On-board user LEDs / keys (per the manual's tables in 2.2.6 / 2.2.7),
# useful for bring-up/status while porting -- optional in the top level.
# ---------------------------------------------------------------------
set_property PACKAGE_PIN R26 [get_ports {status_led[0]}]
set_property PACKAGE_PIN P26 [get_ports {status_led[1]}]
set_property PACKAGE_PIN N26 [get_ports {status_led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {status_led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {status_led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {status_led[2]}]

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

# ---------------------------------------------------------------------------
# Fan, on JP5's spare BANK12 I/O.
#
# Deliberately at the FAR END of the header (pins 43/44), immediately beside
# the 5V0 pins at 49/50 -- so a fan lead picks up power and PWM from the same
# corner, and pins 3..42 stay contiguous for a display/touch panel.
#
# Bank 12's VCCO is the 3V3 rail (see the SW2/SW3 note above), so LVCMOS33.
# A 4-pin fan's PWM input is 3.3V-tolerant; a 2-pin fan needs a MOSFET, gate
# driven from fan_pwm.
#
#   JP5 pin 43 = BANK12_U24 -> fan_pwm      (24.4kHz PWM out)
#   JP5 pin 44 = BANK12_U25 -> fan_tach_in  (open-collector tach, needs pull-up)
# ---------------------------------------------------------------------------
set_property PACKAGE_PIN U24 [get_ports fan_pwm]
set_property PACKAGE_PIN U25 [get_ports fan_tach_in]
set_property IOSTANDARD LVCMOS33 [get_ports fan_pwm]
set_property IOSTANDARD LVCMOS33 [get_ports fan_tach_in]
# Tach is open-collector on every fan I know of; without this it floats and
# reads as random RPM rather than zero.
set_property PULLUP true [get_ports fan_tach_in]

# ---------------------------------------------------------------------------
# ILI9341 panel + XPT2046 touch, on JP5's spare BANK12 I/O.
#
# Contiguous at the low end of the header (pins 3-11) so a ribbon lands
# naturally; the fan sits at 43/44 by the 5V0 pins, well clear.
#
# SCLK/MOSI/MISO are shared between panel and touch controller; each has its
# own chip select. Bank 12's VCCO is the 3V3 rail, so LVCMOS33 throughout --
# both devices are 3.3V parts.
#
#   JP5  3 (AD21) lcd_sclk     JP5  9 (V21) lcd_bl
#   JP5  4 (AE21) lcd_mosi     JP5 10 (W21) touch_cs_n
#   JP5  5 (AE22) lcd_miso     JP5 11 (Y22) touch_irq
#   JP5  6 (AF22) lcd_cs_n
#   JP5  7 (AE23) lcd_dc
#   JP5  8 (AF23) lcd_rst_n
# ---------------------------------------------------------------------------
set_property PACKAGE_PIN AD21 [get_ports lcd_sclk]
set_property PACKAGE_PIN AE21 [get_ports lcd_mosi]
set_property PACKAGE_PIN AE22 [get_ports lcd_miso]
set_property PACKAGE_PIN AF22 [get_ports lcd_cs_n]
set_property PACKAGE_PIN AE23 [get_ports lcd_dc]
set_property PACKAGE_PIN AF23 [get_ports lcd_rst_n]
set_property PACKAGE_PIN V21  [get_ports lcd_bl]
set_property PACKAGE_PIN W21  [get_ports touch_cs_n]
set_property PACKAGE_PIN Y22  [get_ports touch_irq]
# Written out one per line rather than via a foreach. The loop form did not
# apply -- lcd_miso came out of synthesis with no IOSTANDARD at all, so Vivado
# defaulted it to LVCMOS18 and DRC failed the whole implementation on a bank
# 12 Vcc conflict (bank 12 is the 3V3 rail). Explicit lines also match the
# rest of this file, and a missing one is visible in a diff.
set_property IOSTANDARD LVCMOS33 [get_ports lcd_sclk]
set_property IOSTANDARD LVCMOS33 [get_ports lcd_mosi]
set_property IOSTANDARD LVCMOS33 [get_ports lcd_miso]
set_property IOSTANDARD LVCMOS33 [get_ports lcd_cs_n]
set_property IOSTANDARD LVCMOS33 [get_ports lcd_dc]
set_property IOSTANDARD LVCMOS33 [get_ports lcd_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports lcd_bl]
set_property IOSTANDARD LVCMOS33 [get_ports touch_cs_n]
set_property IOSTANDARD LVCMOS33 [get_ports touch_irq]
# XPT2046 PENIRQ is open-drain.
set_property PULLUP true [get_ports touch_irq]
