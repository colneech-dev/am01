#!/usr/bin/env bash
# Parallel A/B test against the running seed-1 balanced-partition route:
# same floorplan JSON (out_2miner/am01_qmtech_top.fp.json), same seed=1, only
# --placer-heap-beta changed from nextpnr's default (0.9) to 0.5 (more
# aggressive spreading). floorplan_brams.py only pins RAMB18E1 BELs -- every
# LUT/FF around them is still free for HeAP to place -- so beta is the lever
# that can push that free logic off the saturated BRAM columns instead of
# letting pure wirelength pack it right back onto them.
#
# Does NOT touch or restart the running seed-1 job. Separate output dir, log,
# pid file.
set -uo pipefail
cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7
NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
FP=out_2miner/am01_qmtech_top.fp.json
BETA="${BETA:-0.5}"
SEED="${SEED:-1}"
d="seedrun/2miner_beta${BETA}_s${SEED}"
mkdir -p "$d"

echo $$ > .pid_2miner_beta
trap "rm -f .pid_2miner_beta" EXIT

echo "=== 2miner beta=$BETA seed=$SEED -- $(date -Is) ==="
env NEXTPNR_ARC_MAX_VISIT=2000000 NEXTPNR_ROUTER2_MAX_STALL=250 \
    NEXTPNR_CRIT_DIST_EXP=1.0 \
    "$NEXTPNR" --chipdb "$CHIPDB" \
    --json "$FP" --xdc "$XDC" \
    --freq 133.33 --seed "$SEED" --placer-heap-beta "$BETA" \
    --log "$d/route.log" > "$d/console" 2>&1
echo "exit $? -- $(date -Is)"
