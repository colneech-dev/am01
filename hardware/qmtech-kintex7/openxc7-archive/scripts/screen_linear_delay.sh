#!/usr/bin/env bash
# Placement-only screen of the delay-model shape fix.
#
# NEXTPNR_LINEAR_DELAY=1 removes the concave knee in estimateDelay and
# predictDelay. Stock, marginal cost per tile FALLS with distance -- 45 ps/tile
# for the first 18 x-tiles then 15, 90 ps/tile for the first 6 y-tiles then 30 --
# while Vivado measures the real rate at ~99 ps/tile and essentially flat. The
# error changes sign around 13 tiles, so beyond that the placer is told pulling a
# distant critical net closer is nearly free.
#
# Criticality is scale-invariant (timing.cc:678-680), so only the SHAPE of this
# curve reaches the placer. That is why this is a shape fix and not a calibration
# factor -- multiplying the model by the measured 1.86x would provably change
# nothing.
#
# NEXTPNR_CRIT_DIST_EXP attacks the same under-weighting from the other side, in
# the bound2bound net weight rather than the delay model, so the pair is tested
# together as well as separately.
#
# SCREEN ONLY. The placer's post-place estimate and the routed frequency diverge
# badly here (118.20 estimated vs 89.30 routed on the baseline). These numbers
# rank candidates; only a full route produces a result.
#
# Reference, same netlist:
#   baseline                 timing cost 13045   wirelen 4260448
#   NEXTPNR_CRIT_DIST_EXP=1  timing cost  8685   wirelen 4106478
set -euo pipefail

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
JSON=out_nm1_nosr/am01_qmtech_top_v68.json

run() {
    local tag="$1"; shift
    echo "=== $tag : $* ==="
    env "$@" "$NEXTPNR" \
        --chipdb "$CHIPDB" --json "$JSON" --xdc "$XDC" \
        --freq 133.33 --no-route --log "screen_${tag}.pnr.log" > /dev/null 2>&1 || true
    grep -a 'timing cost' "screen_${tag}.pnr.log" | tail -1 || echo "  (no SA line)"
}

run lindelay      NEXTPNR_LINEAR_DELAY=1
run lindelay_cde10 NEXTPNR_LINEAR_DELAY=1 NEXTPNR_CRIT_DIST_EXP=1.0

echo
echo "=== summary (screen only) ==="
printf '%-20s %s\n' "baseline" "timing cost 13045   wirelen 4260448"
printf '%-20s %s\n' "cde10" "timing cost  8685   wirelen 4106478"
for t in lindelay lindelay_cde10; do
    line=$(grep -a 'timing cost' "screen_${t}.pnr.log" 2>/dev/null | tail -1 || true)
    printf '%-20s %s\n' "$t" "${line#*: }"
done
