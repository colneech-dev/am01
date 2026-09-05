#!/usr/bin/env bash
# Full place-and-route with NEXTPNR_HPWL_SCALE_FIX=1.
#
# WHY THIS ONE
# ------------
# Screen results (SA final timing cost / wirelength; baseline 13045 / 4260448):
#
#   CRIT_DIST_EXP=1.0   8685   4106478    <- best placement metrics
#   HPWL_SCALE_FIX=1   11299   3986156    <- best WIRELENGTH of anything tested
#   SMALL_BETA=0.4     11646   4249226
#   LINEAR_DELAY=1     22522   4198320    <- refuted, worst of all
#
# CRIT_DIST_EXP=1.0 won the screen and then FAILED to route: at iteration 31 it
# sat at overused=1595 where the baseline was at 6. It buys short critical nets
# by making everything else longer, and the router cannot absorb that. This is
# the shape Spindler (DATE'07, Fig. 3) documents -- HPWL improves monotonically
# with routing weight while ROUTED wirelength has a minimum partway along.
#
# HPWL_SCALE_FIX is the opposite kind of change: it fixes an upstream error in
# the y-axis weight (hpwl_scale applied such that the term is off by k^2 in the
# wrong direction) and it IMPROVED wirelength rather than trading it away. A
# placement with less total wirelength should be easier to route, not harder,
# so this is the candidate most likely to convert a screen win into a routed one.
#
# WHAT TO WATCH
# -------------
# Convergence first, frequency second. Compare `overused` against the baseline
# at the SAME iteration -- baseline reached single digits by iter 25 and 0 by
# iter 45. A run still in the hundreds at iter 30 is not going to converge, and
# its frequency would be meaningless.
#
# Judge on the ROUTED "Max frequency" line, not the post-place one. The two
# diverged 118.20 -> 89.30 on the baseline, and the post-place estimator has no
# fanout term at all -- which matters here, because the design's worst net
# (crypt.progress[1]) has 644 sinks.
set -euo pipefail

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
JSON=out_nm1_nosr/am01_qmtech_top_v68.json
OUT=out_nm1_nosr

for f in "$NEXTPNR" "$CHIPDB" "$XDC" "$JSON"; do
    [ -e "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

echo "== NEXTPNR_HPWL_SCALE_FIX=1, full place and route =="
NEXTPNR_HPWL_SCALE_FIX=1 "$NEXTPNR" \
    --chipdb "$CHIPDB" \
    --json "$JSON" \
    --xdc "$XDC" \
    --freq 133.33 \
    --write "$OUT/placed_hpwlfix.json" \
    --fasm "$OUT/am01_qmtech_top_hpwlfix.fasm" \
    --log "$OUT/am01_qmtech_top_hpwlfix.pnr.log"

echo "== routed result =="
grep -a "Max frequency for clock" "$OUT/am01_qmtech_top_hpwlfix.pnr.log" | tail -2
