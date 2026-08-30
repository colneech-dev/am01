#!/usr/bin/env bash
# Fill the missing quadrant: Vivado's PLACEMENT, nextpnr's ROUTER.
#
#     place     route     clk_h
#     nextpnr   nextpnr   89.30 -> 93.28   (BRAM floorplan + CRIT_DIST_EXP)
#     nextpnr   Vivado    63.55
#     Vivado    Vivado   158.81
#     Vivado    nextpnr   <- this
#
# WHY IT MATTERS
# --------------
# It decides whether the remaining 1.7x is addressable from the placer at all:
#   near 158 -> placement is the whole gap; mimicking it is the road, and the
#               BRAM floorplan result is the first step along it
#   near  90 -> our router shares the blame and copying placement will not help
#
# Note the second row above: Vivado's router scores 63.55 on OUR placement,
# BELOW our own router's 89.30. Our placement is not merely worse, it is
# actively hard to route.
#
# WAITS ON THE EXPORT
# -------------------
# Vivado must first place the -norename netlist and export cell->BEL with
# yosys-compatible names. The pre-existing vivado_placement.txt CANNOT be used:
# its cells are named _20829_ (write_verilog without -norename) and it predates
# netlist_norename_v68.v by six minutes. Baking it matched 423 of 70071 cells
# (0.6%) -- only the BRAMs, whose names are RTL-derived and stable.
#
# Waits on the artefact, not the process table: pgrep/pkill -f match the
# checking command's own command line and have killed parent shells here.
set -euo pipefail

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

EXPORT=vivado_placement_norename_v68.txt
SRC=out_nm1_nosr/am01_qmtech_top_v68.json
BAKED=out_nm1_nosr/am01_qmtech_top_vplace.json
TAG=vplace
OUT=out_nm1_nosr

echo "== waiting for $EXPORT =="
deadline=$(( $(date +%s) + 4*3600 ))
while [ ! -s "$EXPORT" ]; do
    if [ "$(date +%s)" -gt "$deadline" ]; then
        echo "TIMEOUT: Vivado never produced $EXPORT"
        tail -3 vivado_place_v68.console.txt 2>/dev/null | cut -c1-120
        exit 1
    fi
    sleep 60
done
# let Vivado finish flushing the file
sleep 30
echo "   export has $(wc -l < "$EXPORT") lines"

echo "== baking Vivado placement into the netlist =="
python3 bake_vivado_placement_v68.py "$SRC" "$BAKED" || {
    echo "ERROR: bake failed"; exit 1; }

echo "== routing Vivado's placement with nextpnr =="
NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
DONE="$OUT/.done_$TAG"
rm -f "$DONE"
trap 'touch "$DONE"' EXIT

NEXTPNR_ARC_MAX_VISIT=2000000 NEXTPNR_ROUTER2_MAX_STALL=250 "$NEXTPNR" \
    --chipdb ./chipdb/xc7k325tffg676-1.bin \
    --json "$BAKED" \
    --xdc /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc \
    --freq 133.33 \
    --write "$OUT/placed_$TAG.json" \
    --fasm "$OUT/am01_qmtech_top_$TAG.fasm" \
    --log "$OUT/am01_qmtech_top_$TAG.pnr.log" || echo "   nextpnr exited non-zero"

echo "== RESULT: Vivado place + nextpnr route =="
echo "   (nextpnr+nextpnr 93.28 | nextpnr+Vivado 63.55 | Vivado+Vivado 158.81)"
grep -a "Max frequency for clock" "$OUT/am01_qmtech_top_$TAG.pnr.log" 2>/dev/null | tail -2
grep -a 'iter=' "$OUT/am01_qmtech_top_$TAG.pnr.log" 2>/dev/null | tail -1
