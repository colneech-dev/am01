#!/usr/bin/env bash
# Placement-only screen of placer knobs, to rank candidates cheaply.
#
# WHY A SCREEN
# ------------
# A full route on this design is ~45 router iterations and takes hours. Running
# every candidate to a routed number would take a day. Placement-only (--no-route)
# costs ~10 minutes and yields the SA refinement's own `timing cost` and
# `wirelen`, which is enough to RANK candidates.
#
# THIS IS A SCREEN, NOT A RESULT. The placer's post-place estimate and the
# routed frequency diverge badly on this design -- 118.20 MHz estimated vs
# 89.30 MHz routed on the baseline -- and treating an estimate as a result is a
# mistake made repeatedly in this work. Only the winner gets a full route, and
# only the routed number gets reported as an outcome.
#
# Reference points measured on the same netlist:
#   baseline (no knobs)      timing cost 13045   wirelen 4260448
#   NEXTPNR_CRIT_DIST_EXP=1  timing cost  8685   wirelen 4106478
#
# Usage:  bash screen_placer_knobs.sh
set -euo pipefail

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
JSON=out_nm1_nosr/am01_qmtech_top_v68.json

run() {
    local tag="$1"; shift
    local log="screen_${tag}.pnr.log"
    echo "=== $tag : $* ==="
    env "$@" "$NEXTPNR" \
        --chipdb "$CHIPDB" --json "$JSON" --xdc "$XDC" \
        --freq 133.33 --no-route --log "$log" > /dev/null 2>&1 || true
    grep -a 'at iteration #.*timing cost' "$log" | tail -1 || echo "  (no SA line)"
}

# Half-strength critical-distance correction, to see whether 1.0 overshoots.
run cde05 NEXTPNR_CRIT_DIST_EXP=0.5

# Upstream y-axis weight error: hpwl_scale_y is applied such that the y term is
# off by k^2 in the wrong direction, on the axis this design's critical path
# spans 192 tiles of.
run hpwlfix NEXTPNR_HPWL_SCALE_FIX=1

# Density target for <4-bel tiles. BRAM tiles hold 2 RAMB18E1 bels, so they
# bypass beta entirely and sit at a 100% density target at every beta. 420
# RAMB18E1 against 445 BRAM tiles leaves room for one per tile.
run smallbeta04 NEXTPNR_SMALL_BETA=0.4

# The two most promising in combination.
run cde10_hpwlfix NEXTPNR_CRIT_DIST_EXP=1.0 NEXTPNR_HPWL_SCALE_FIX=1
run cde10_smallbeta NEXTPNR_CRIT_DIST_EXP=1.0 NEXTPNR_SMALL_BETA=0.4

echo
echo "=== summary (screen only -- routed numbers still required) ==="
printf '%-20s %s\n' "baseline" "timing cost 13045   wirelen 4260448"
printf '%-20s %s\n' "cde10 (full run)" "timing cost  8685   wirelen 4106478"
for f in screen_*.pnr.log; do
    [ -e "$f" ] || continue
    t="${f#screen_}"; t="${t%.pnr.log}"
    line=$(grep -a 'at iteration #.*timing cost' "$f" | tail -1 || true)
    printf '%-20s %s\n' "$t" "${line#*: }"
done
