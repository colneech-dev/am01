#!/usr/bin/env bash
# Re-synthesise and place NUM_MINERS=1 with SRLs disabled.
#
# WHY
# ---
# The decisive "nextpnr place -> Vivado route" experiment failed in Vivado's
# PLACER, not on name mapping:
#
#   applied 136580 / 136636 (100.0%), failed 56
#   ERROR: [Place 30-484] The packing of LUTRAM/SRL instances into capable
#          slices could not be obeyed.  ... 2 LUTRAMs/SRLs failed to place.
#          ... type SRLC32E
#
# So the name mapping is solved; the blocker is that Vivado's packer cannot
# place 2 of the 6 SRLC32E cells nextpnr was happy with. build.sh's SRL knob
# defaults to 1 because SRLs stopped hurting the nextpnr ROUTER -- but that
# says nothing about Vivado's placer, and out_nm1_nosr (named for -nosrl) has
# been holding SRL-bearing netlists ever since.
#
# An SRL-free netlist unblocks the comparison and costs a few hundred FFs.
# Output goes to a NEW directory so the existing results are untouched and the
# directory name does not lie about its contents.
set -euo pipefail

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

SCRATCH=/mnt/c/Users/Colin/AppData/Local/Temp/claude/c--Users-Colin-Documents-GitHub-am01/057d0e04-8974-418d-8c78-e3f71a81f301/scratchpad
HW=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/hdl
ODO=/mnt/c/Users/Colin/Documents/GitHub/am01/hdl/odocrypt

# build.sh defaults XDC to <first src dir>/<top>.xdc, and the first source is the
# generated NUM_MINERS=1 top in the scratchpad -- so the default resolves into a
# temp directory. Point it at the board pinout explicitly.
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc \
SRL=0 FREQ=133.33 ./build.sh am01_qmtech_top out_nm1_srl0 \
    "$SCRATCH/am01_qmtech_top_nm1.v" \
    "$HW/clk_gen_hash.v" \
    "$HW/odocrypt_gpio_wrapper.v" \
    "$ODO/atomminer_misc.v" \
    "$ODO/encrypt.v" \
    "$ODO/keccak800.v" \
    "$ODO/miner.v"
