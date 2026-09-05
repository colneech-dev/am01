#!/usr/bin/env bash
# Placement-only run, to measure how far post-place repair moves cells.
#
# WHY
# ---
# The v68base placement relocates 11790 of 42597 cells (28%) in
# "post-place repair", and the log reports only that COUNT. A count cannot
# distinguish "everything moved one tile" from "a few things moved across the
# die", and those have opposite consequences.
#
# It matters because the measured critical path on that placement is a
# flop-to-flop net with NO logic between the endpoints:
#
#   SLICE_X5Y137 -> SLICE_X26Y269   (dX 21, dY 132)
#   logic 0.322 ns   net 15.104 ns
#
# arch_place.cc now buckets the repair move radius and names the furthest-moved
# cell. --no-route skips the expensive part: the repair log line is emitted
# during placement, so routing adds hours and tells us nothing here.
#
# Settings match the v68base run this is diagnosing (defaults, no floorplan).
set -euo pipefail

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
JSON=out_nm1_nosr/am01_qmtech_top_v68.json

for f in "$NEXTPNR" "$CHIPDB" "$XDC" "$JSON"; do
    [ -e "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

"$NEXTPNR" \
    --chipdb "$CHIPDB" \
    --json "$JSON" \
    --xdc "$XDC" \
    --freq 133.33 \
    --no-route \
    --log repair_stats.pnr.log
