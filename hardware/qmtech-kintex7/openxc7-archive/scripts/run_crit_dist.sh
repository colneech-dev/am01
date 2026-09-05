#!/usr/bin/env bash
# Full place-and-route with NEXTPNR_CRIT_DIST_EXP enabled.
#
# WHY
# ---
# HeAP's bound2bound weight is 1/(users * distance) -- the standard trick for
# approximating linear HPWL from a quadratic solver. It means a LONG net gets
# LESS pull, which is the opposite of what timing needs. placer_heap.cc records
# the measurement on this design:
#
#   375-tile critical net : 1/(7*375) * 11  ~= 0.0042
#   5-tile slack net      : 1/(7*5)   *  1  ~= 0.029
#
# The short slack net has ~7x more pull than the critical net crossing the die.
# The criticality boost caps at (1 + timingWeight) = 11x and cannot overcome a
# 375x distance discount. It compounds with hpwl_scale_y = 2, so the y axis --
# where the critical net spans 268 tiles vs 107 in x -- is discounted twice.
#
# NEXTPNR_CRIT_DIST_EXP=k scales the weight back up by distance^(k*crit):
#   crit = 0        -> unchanged (wirelength-efficient HPWL behaviour)
#   crit = 1, k = 1 -> distance cancels entirely, i.e. quadratic: aggressively
#                      shortened
# k = 0 disables (bit-identical to before), which is the current default.
#
# This matches the measured symptom exactly. nextpnr's own critical path on the
# shipped placement is a BRAM output reaching its consumer LUT across
# (19,343) -> (50,151):
#
#   Source ...round17.sboxes.sbox14inst.mem.0.0.DOPADOP0   2.1 ns
#   Net    round17.mid[1][158]   8.8 ns   budget 0.000000 ns
#   Sink   $abc$...$497312.A5
#
# WHAT TO WATCH
# -------------
# Judge on the ROUTED frequency, not the post-place estimate: those diverged
# 118.20 -> 89.30 on the baseline, and reading the estimate as a result is a
# mistake made repeatedly in this work. Also watch that routing still reaches
# overused=0; pulling critical nets tight raises congestion, and an unconverged
# route makes the frequency meaningless.
#
# Usage:  bash run_crit_dist.sh <k>        e.g. 1.0, then 0.5
set -euo pipefail

K="${1:?usage: run_crit_dist.sh <crit_dist_exp>}"
TAG="cde${K/./}"

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
JSON=out_nm1_nosr/am01_qmtech_top_v68.json
OUT=out_nm1_nosr

for f in "$NEXTPNR" "$CHIPDB" "$XDC" "$JSON"; do
    [ -e "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

echo "== NEXTPNR_CRIT_DIST_EXP=$K, full place and route =="
NEXTPNR_CRIT_DIST_EXP="$K" "$NEXTPNR" \
    --chipdb "$CHIPDB" \
    --json "$JSON" \
    --xdc "$XDC" \
    --freq 133.33 \
    --write "$OUT/placed_$TAG.json" \
    --fasm "$OUT/am01_qmtech_top_$TAG.fasm" \
    --log "$OUT/am01_qmtech_top_$TAG.pnr.log"

echo "== routed result =="
grep -a "Max frequency for clock\|unrouted=0\|post-place repair" \
    "$OUT/am01_qmtech_top_$TAG.pnr.log" | tail -6
