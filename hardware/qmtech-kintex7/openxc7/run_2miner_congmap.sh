#!/usr/bin/env bash
# Ground-truth congestion feedback, phase 1: force the same TILE_NETS/
# WIRE_DEMAND placement through to completion instead of hard-failing on the
# residual, and export REAL router2 per-tile overuse (not a placement-time
# proxy) via NEXTPNR_DUMP_CONGESTION. That map is the input to phase 2
# (NEXTPNR_CONGESTION_MAP) once this finishes -- see run_2miner_congmap2.sh.
#
# Runs alongside the still-live plain congestion-aware run (seed5), which is
# drifting rather than converging (iter=148, overuse=184, up from 145 at
# iter=129) -- not killed, since it is cheap to let it finish confirming the
# plateau while this captures the ground truth in parallel.
set -uo pipefail
cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7
NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
FP=out_2miner/am01_qmtech_top.fp.json
SEED="${SEED:-5}"
TILE_NETS="${TILE_NETS:-8}"
WIRE_DEMAND="${WIRE_DEMAND:-5.0}"
d="seedrun/2miner_congmap_s${SEED}_tn${TILE_NETS}_wd${WIRE_DEMAND}"
mkdir -p "$d"

echo $$ > .pid_2miner_congmap
trap "rm -f .pid_2miner_congmap" EXIT

echo "=== 2miner congestion-MAP-PHASE1 seed=$SEED TILE_NETS=$TILE_NETS WIRE_DEMAND=$WIRE_DEMAND -- $(date -Is) ==="
env NEXTPNR_ARC_MAX_VISIT=2000000 NEXTPNR_ROUTER2_MAX_STALL=250 \
    NEXTPNR_CRIT_DIST_EXP=1.0 \
    NEXTPNR_TILE_NETS="$TILE_NETS" NEXTPNR_WIRE_DEMAND="$WIRE_DEMAND" \
    NEXTPNR_SKIP_FAILED_ARCS=1 NEXTPNR_DUMP_CONGESTION="$d/congestion.csv" \
    "$NEXTPNR" --chipdb "$CHIPDB" \
    --json "$FP" --xdc "$XDC" \
    --freq 133.33 --seed "$SEED" \
    --log "$d/route.log" > "$d/console" 2>&1
echo "exit $? -- $(date -Is)"
