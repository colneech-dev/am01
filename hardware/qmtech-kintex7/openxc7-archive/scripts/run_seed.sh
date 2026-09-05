#!/usr/bin/env bash
# Full place-and-route with an explicit SEED, arc budget and stall cap.
#
# WHY SEED
# --------
# Seed sensitivity on this design is qualitative, not marginal. Recorded
# earlier: seed 1 converged at router iteration 45; seed 7 never converged in
# 119. So a configuration that fails to converge on one seed has not been shown
# to fail -- it has been shown to fail ON THAT SEED.
#
# That matters for WIRE_DEMAND=1.0, which is the only knob whose failures look
# like near-misses rather than refusals:
#   unbounded : oscillated 6..33, killed at iter 174
#   200k      : hard route error at iter 2 (arc budget exhausted, BRAM egress)
#   2M        : descending through 13 when max_stall=50 cut it off; best was 6
#
# WHY THE STALL CAP IS ALSO SET
# -----------------------------
# max_stall defaults to 50 and counts iterations since the BEST overuse
# improved -- not since the last improvement. wd10_2m was descending
# monotonically (25, 24, 23, 17, 19, 16, 14, 13) when it was stopped, because
# none of those beat the 6 it had reached much earlier. Without lifting the cap
# a longer run stops in exactly the same place for exactly the same reason, and
# the seed comparison would measure nothing.
#
# Usage:  bash run_seed.sh <tag> <seed> <budget> <stall> <KNOB=VAL>
#   e.g.  bash run_seed.sh wd10_s3 3 3000000 250 NEXTPNR_WIRE_DEMAND=1.0
set -euo pipefail

TAG="${1:?usage: run_seed.sh <tag> <seed> <budget> <stall> <KNOB=VAL>}"
SEED="${2:?seed}"
BUDGET="${3:?budget}"
STALL="${4:?stall}"
shift 4

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
JSON=out_nm1_nosr/am01_qmtech_top_v68.json
OUT=out_nm1_nosr

for f in "$NEXTPNR" "$CHIPDB" "$XDC" "$JSON"; do
    [ -e "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

DONE="$OUT/.done_$TAG"
rm -f "$DONE"
trap 'touch "$DONE"' EXIT

echo "== $TAG : seed=$SEED ARC_MAX_VISIT=$BUDGET MAX_STALL=$STALL $* =="
env NEXTPNR_ARC_MAX_VISIT="$BUDGET" NEXTPNR_ROUTER2_MAX_STALL="$STALL" "$@" "$NEXTPNR" \
    --chipdb "$CHIPDB" \
    --json "$JSON" \
    --xdc "$XDC" \
    --freq 133.33 \
    --seed "$SEED" \
    --write "$OUT/placed_$TAG.json" \
    --fasm "$OUT/am01_qmtech_top_$TAG.fasm" \
    --log "$OUT/am01_qmtech_top_$TAG.pnr.log"

echo "== $TAG routed result (baseline 89.30 MHz) =="
grep -a "Max frequency for clock" "$OUT/am01_qmtech_top_$TAG.pnr.log" | tail -2
grep -a 'iter=' "$OUT/am01_qmtech_top_$TAG.pnr.log" | tail -1
