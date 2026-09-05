#!/usr/bin/env bash
# Tier 1+2 congestion-aware placement test: NEXTPNR_TILE_NETS (marginal
# routing-demand penalty at legalisation, targets the verified geometric-
# median multi-BRAM-driver hotspot) plus NEXTPNR_WIRE_DEMAND (RUDY estimate
# feeding HeAP's spreader, which is otherwise blind to routing demand on a
# design this lightly occupied in LUTs/FFs). Both built in
# nextpnr-xilinx-heatmap commit 42cecc26, previously unmeasured on any real
# design. Reuses the already-built, already-validated balanced-partition
# floorplan JSON. Runs alongside seed1 (finished/failed) and seed3
# (running), does not touch them.
set -uo pipefail
cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7
NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
FP=out_2miner/am01_qmtech_top.fp.json
SEED="${SEED:-5}"
TILE_NETS="${TILE_NETS:-8}"
WIRE_DEMAND="${WIRE_DEMAND:-5.0}"
d="seedrun/2miner_congaware_s${SEED}_tn${TILE_NETS}_wd${WIRE_DEMAND}"
mkdir -p "$d"

echo $$ > .pid_2miner_congaware
trap "rm -f .pid_2miner_congaware" EXIT

echo "=== 2miner congestion-aware seed=$SEED TILE_NETS=$TILE_NETS WIRE_DEMAND=$WIRE_DEMAND -- $(date -Is) ==="
env NEXTPNR_ARC_MAX_VISIT=2000000 NEXTPNR_ROUTER2_MAX_STALL=250 \
    NEXTPNR_CRIT_DIST_EXP=1.0 \
    NEXTPNR_TILE_NETS="$TILE_NETS" NEXTPNR_WIRE_DEMAND="$WIRE_DEMAND" \
    "$NEXTPNR" --chipdb "$CHIPDB" \
    --json "$FP" --xdc "$XDC" \
    --freq 133.33 --seed "$SEED" \
    --log "$d/route.log" > "$d/console" 2>&1
echo "exit $? -- $(date -Is)"
