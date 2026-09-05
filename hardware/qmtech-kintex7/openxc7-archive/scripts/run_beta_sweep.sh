#!/usr/bin/env bash
# Full place-and-route at higher placement density.
#
# WHY BETA
# --------
# The measured critical path on the current placement is a flop-to-flop net with
# NO logic between the endpoints:
#
#   SLICE_X5Y137 -> SLICE_X26Y269   (dX 21, dY 132)
#   logic 0.322 ns   net 15.104 ns
#
# Vivado's router, given that identical placement, reached only 63.55 MHz --
# below our own router's 89.30 -- so no routing change can fix it. The two flops
# are simply too far apart.
#
# cfg.beta is the maximum placement density: CutSpreader::overused() declares a
# tile overfull at `cells > beta * bels` and spreads. This design runs at
# beta=0.400, lower than every other arch in nextpnr (upstream default 0.9,
# ecp5 0.75, nexus/mistral/himbaechel-xilinx 0.5). A lower beta spreads more
# aggressively, and on a design at 9% LUT utilisation that is spreading for no
# reason.
#
# Upstream precedent: PR #1527 relaxed a density restriction on GateMate for
# "a free Fmax improvement" (~3 MHz median over 100 seeds). Density is the
# sanctioned routability/Fmax lever, and --placer-heap-beta only became usable
# here once the silent-discard bug on the xilinx arch was fixed locally.
#
# MEASURE THE ROUTED NUMBER, NOT THE ESTIMATE. The post-place estimate and the
# routed result diverge badly on this design (118.20 estimate -> 89.30 routed on
# the v68base run), and reading the estimate as a result is a mistake that has
# been made repeatedly here. This runs a full route.
#
# Usage:  bash run_beta_sweep.sh <beta>          e.g. 0.9
set -euo pipefail

BETA="${1:?usage: run_beta_sweep.sh <beta>}"
TAG="beta${BETA/./}"

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
JSON=out_nm1_nosr/am01_qmtech_top_v68.json
OUT=out_nm1_nosr

for f in "$NEXTPNR" "$CHIPDB" "$XDC" "$JSON"; do
    [ -e "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

echo "== beta=$BETA, full place and route =="
"$NEXTPNR" \
    --chipdb "$CHIPDB" \
    --json "$JSON" \
    --xdc "$XDC" \
    --freq 133.33 \
    --placer-heap-beta "$BETA" \
    --write "$OUT/placed_$TAG.json" \
    --fasm "$OUT/am01_qmtech_top_$TAG.fasm" \
    --log "$OUT/am01_qmtech_top_$TAG.pnr.log"

echo "== result (routed) =="
grep -a "Max frequency for clock\|post-place repair\|move radius\|furthest move" \
    "$OUT/am01_qmtech_top_$TAG.pnr.log" | tail -8
