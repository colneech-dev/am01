#!/usr/bin/env bash
# Ground-truth congestion feedback, phase 2: feed the REAL per-tile overuse
# measured by run_2miner_congmap.sh's phase-1 run (188 overused wires, 319
# nets left with unrouted arcs, accepted via SKIP_FAILED_ARCS at iter=574)
# back into a fresh placement, via NEXTPNR_CONGESTION_MAP -- biasing
# legalisation away from the tiles that measurably failed, rather than a
# placement-time proxy (TILE_NETS/WIRE_DEMAND) guessing where they might be.
#
# TILE_NETS/WIRE_DEMAND are kept on too: CONGESTION_MAP is a targeted
# correction layered on top of them, not a replacement.
set -uo pipefail
cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7
NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
FP=out_2miner/am01_qmtech_top.fp.json
SEED="${SEED:-7}"
TILE_NETS="${TILE_NETS:-8}"
WIRE_DEMAND="${WIRE_DEMAND:-5.0}"
CONGESTION_MAP="${CONGESTION_MAP:-seedrun/2miner_congmap_s5_tn8_wd5.0/congestion.csv}"
CONGESTION_W="${CONGESTION_W:-2}"
d="seedrun/2miner_congmap2_s${SEED}_tn${TILE_NETS}_wd${WIRE_DEMAND}_cw${CONGESTION_W}"
mkdir -p "$d"

echo $$ > .pid_2miner_congmap2
trap "rm -f .pid_2miner_congmap2" EXIT

echo "=== 2miner congestion-MAP-PHASE2 seed=$SEED TILE_NETS=$TILE_NETS WIRE_DEMAND=$WIRE_DEMAND CONGESTION_MAP=$CONGESTION_MAP CONGESTION_W=$CONGESTION_W -- $(date -Is) ==="
env NEXTPNR_ARC_MAX_VISIT=2000000 NEXTPNR_ROUTER2_MAX_STALL=250 \
    NEXTPNR_CRIT_DIST_EXP=1.0 \
    NEXTPNR_TILE_NETS="$TILE_NETS" NEXTPNR_WIRE_DEMAND="$WIRE_DEMAND" \
    NEXTPNR_CONGESTION_MAP="$CONGESTION_MAP" NEXTPNR_CONGESTION_W="$CONGESTION_W" \
    "$NEXTPNR" --chipdb "$CHIPDB" \
    --json "$FP" --xdc "$XDC" \
    --freq 133.33 --seed "$SEED" \
    --log "$d/route.log" > "$d/console" 2>&1
echo "exit $? -- $(date -Is)"
