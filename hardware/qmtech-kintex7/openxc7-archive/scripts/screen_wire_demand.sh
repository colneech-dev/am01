#!/usr/bin/env bash
# Screen the in-placement congestion estimator (RUDY) at several thresholds.
#
# WHAT THIS IS
# ------------
# build_wire_demand() (placer_heap.cc:1649) computes a RUDY routing-demand map
# from the CURRENT cell positions, every time the spreader runs -- so it adapts
# during placement rather than importing a map from a previous route:
#
#   per net: bbox w x h, hpwl = w + h, per_tile = hpwl / (w * h)
#   accumulate per_tile into every tile of the bbox
#   skip nets on dedicated global routing (isGlobalNet)
#
# wire_congested(x,y) then reports tiles above NEXTPNR_WIRE_DEMAND as
# overutilised, which makes find_overused_regions() create a region there and
# the spreader thin it out.
#
# WHY IT MATTERS ON THIS DESIGN
# -----------------------------
# From the code's own comment: the spreader otherwise reacts ONLY to BEL
# overflow, which at 9% LUT utilisation never happens. A placement can be
# locally unroutable and the placer cannot notice, because nothing it measures
# has a problem. That is exactly this design.
#
# CHOOSING THE THRESHOLD
# ----------------------
# per_tile is (w+h)/(w*h): ~1.0 for a 2x2-tile net, ~0.02 for a 100x100 one,
# summed over every net covering the tile. The right cap is not predictable, so
# sweep it. Too high = no tile ever trips = baseline. Too low = everything trips
# = the spreader thins the whole die and wirelength explodes.
#
# SCREEN ONLY. Placement-only numbers rank candidates; they do not settle
# anything. CRIT_DIST_EXP won this same screen (timing cost 8685 vs baseline
# 13045) and then failed to route, sitting at overused~1595 where the baseline
# was at 6. Watch wirelength here as the routability proxy.
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

run wd20 NEXTPNR_WIRE_DEMAND=2.0
run wd10 NEXTPNR_WIRE_DEMAND=1.0
run wd05 NEXTPNR_WIRE_DEMAND=0.5

echo
echo "=== summary (screen only) ==="
printf '%-16s %s\n' "baseline" "timing cost 13045   wirelen 4260448"
printf '%-16s %s\n' "hpwlfix" "timing cost 11299   wirelen 3986156"
for t in wd20 wd10 wd05; do
    line=$(grep -a 'timing cost' "screen_${t}.pnr.log" 2>/dev/null | tail -1 || true)
    printf '%-16s %s\n' "$t" "${line#*: }"
done
