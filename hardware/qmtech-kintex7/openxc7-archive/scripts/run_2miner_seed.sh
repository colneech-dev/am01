#!/usr/bin/env bash
# Additional seed against the same balanced-partition floorplan, default
# placer-heap-beta. Reuses out_2miner/am01_qmtech_top.fp.json (already built).
# Does not touch the running seed-1 job.
set -uo pipefail
cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7
NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
FP=out_2miner/am01_qmtech_top.fp.json
SEED="${SEED:-3}"
d="seedrun/2miner_s${SEED}"
mkdir -p "$d"

echo $$ > .pid_2miner_seed3
trap "rm -f .pid_2miner_seed3" EXIT

echo "=== 2miner seed=$SEED (default beta) -- $(date -Is) ==="
env NEXTPNR_ARC_MAX_VISIT=2000000 NEXTPNR_ROUTER2_MAX_STALL=250 \
    NEXTPNR_CRIT_DIST_EXP=1.0 \
    "$NEXTPNR" --chipdb "$CHIPDB" \
    --json "$FP" --xdc "$XDC" \
    --freq 133.33 --seed "$SEED" \
    --log "$d/route.log" > "$d/console" 2>&1
echo "exit $? -- $(date -Is)"
