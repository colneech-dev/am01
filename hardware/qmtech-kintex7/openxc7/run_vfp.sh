#!/usr/bin/env bash
# Full place-and-route on the Vivado-measured BRAM floorplan.
#
# WHY THIS ONE IS DIFFERENT FROM EVERY OTHER EXPERIMENT THIS SESSION
# ------------------------------------------------------------------
# Every placer knob tried (CRIT_DIST_EXP, WIRE_DEMAND, SMALL_BETA,
# HPWL_SCALE_FIX, LINEAR_DELAY) reweighted a heuristic and hoped. This copies a
# layout that is MEASURED to work: Vivado reaches 158.81 MHz on this exact
# netlist, and verify_bram_spread.py compares both placements in the same
# coordinate system:
#
#   per round          Vivado (158.81)   nextpnr (89.30)
#   column span        2.2 (max 4)       5.2 (max 6)
#   distinct columns   3.2 (max 5)       6.1 (max 7)
#   row span          11.4               6.2
#   columns used       0..5              0..6
#   row range         53..137            0..139
#
# Both place 420 RAMB18 one per tile, none double-packed, so the difference is
# purely WHERE. Vivado confines each round's 20 BRAMs to ~3 adjacent columns;
# nextpnr spreads every round over ~6 of 7, i.e. the whole die width.
#
# That matters because BRAM nets are 10.7% of nets but 42.5% of total HPWL --
# median span 124 tiles against 1 for SLICE nets.
#
# NEITHER EXISTING FLOORPLAN MODE DOES THIS
# -----------------------------------------
# `stripe` (the previous default) spreads each round across ALL columns, exactly
# maximising what Vivado minimises. `block` packs a round into 10 contiguous
# tiles and over-corrects -- its failed arcs were 817 SLICE->SLICE against 37
# BRAM->SLICE, so it crowded that round's ~3300 LUTs rather than saturating BRAM
# egress. The repo comment attributing block mode's failure to "BRAM egress
# capacity" is refuted by that census.
#
# WHAT TO WATCH
# -------------
# 1. Convergence against baseline at the SAME iteration: 395 at iter 9, 60 at
#    17, 14 at 25, 1 at 41, 0 at 45.
# 2. Then the ROUTED "Max frequency", against 89.30 MHz. Ignore the post-place
#    estimate; it has been anti-correlated with the routed result all session.
# 3. Prior floorplan attempts FAILED to converge, so treat non-convergence as
#    the expected outcome and a routed number as the surprise.
set -euo pipefail

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
JSON=out_nm1_nosr/am01_qmtech_top_vfp.json
OUT=out_nm1_nosr
TAG=vfp

for f in "$NEXTPNR" "$CHIPDB" "$XDC" "$JSON"; do
    [ -e "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

DONE="$OUT/.done_$TAG"
rm -f "$DONE"
trap 'touch "$DONE"' EXIT

echo "== $TAG : Vivado-measured BRAM floorplan, full place and route =="
NEXTPNR_ARC_MAX_VISIT=2000000 NEXTPNR_ROUTER2_MAX_STALL=250 "$NEXTPNR" \
    --chipdb "$CHIPDB" \
    --json "$JSON" \
    --xdc "$XDC" \
    --freq 133.33 \
    --write "$OUT/placed_$TAG.json" \
    --fasm "$OUT/am01_qmtech_top_$TAG.fasm" \
    --log "$OUT/am01_qmtech_top_$TAG.pnr.log"

echo "== $TAG routed result (baseline 89.30 MHz) =="
grep -a "Max frequency for clock" "$OUT/am01_qmtech_top_$TAG.pnr.log" | tail -2
grep -a 'iter=' "$OUT/am01_qmtech_top_$TAG.pnr.log" | tail -1
