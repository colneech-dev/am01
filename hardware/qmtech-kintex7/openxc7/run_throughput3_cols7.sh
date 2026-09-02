#!/usr/bin/env bash
# THROUGHPUT=3, 7-column floorplan (adds X6 to build.sh's hardcoded
# --columns 0,1,2,3,4,5). Reuses the already-synthesised netlist -- the
# same trick as run_throughput3_ybase_sweep.sh, so this costs a
# floorplan+route, not a resynthesis.
#
# WHY: the y-base sweep found 40 was already the best row-range candidate
# for the 6-column layout, and none of 0/20/53 beat it (see RESULTS.md
# "y-base sweep"). Column count -- also hardcoded in build.sh, also carried
# over unrefined from the 1-miner default -- was the untested lever. Adding
# X6 (Y0-59, so it only contributes ~20 rows at y-base=40, not a full
# column) gave the floorplanner more total room without changing the row
# range. Measured: 134.86 MHz, PASS at 133.33 MHz (1.53 MHz / ~1.1%
# margin) -- beats the 6-column result (132.71 MHz, technically FAILS) by
# ~2.15 MHz.
set -uo pipefail
cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
NETLIST=out_throughput3/am01_qmtech_top.json
RESULTS=seed_ab_results.tsv
SEEDS="${SEEDS:-1 2 3}"
YBASE="${YBASE:-40}"
COLUMNS="${COLUMNS:-0,1,2,3,4,5,6}"
TAG="throughput3_cols7_yb${YBASE}"

echo $$ > .pid_throughput3_cols7
trap 'rm -f .pid_throughput3_cols7' EXIT

[ -f "$NETLIST" ] || { echo "NETLIST MISSING: $NETLIST -- run run_throughput3.sh first"; exit 1; }

for s in $SEEDS; do
    d="seedrun/throughput3_cols7_s${s}"
    mkdir -p "$d"

    echo "=== floorplan y-base=$YBASE columns=$COLUMNS -- $(date -Is) ==="
    python3 floorplan_brams.py "$NETLIST" "$d/am01_qmtech_top.fp.json" \
        --mode compact --columns "$COLUMNS" --y-base "$YBASE" \
        > "$d/floorplan.log" 2>&1 || { echo "  floorplan FAILED, see $d/floorplan.log"; continue; }
    tail -3 "$d/floorplan.log"

    echo "=== route seed=$s -- $(date -Is) ==="
    env NEXTPNR_ARC_MAX_VISIT=2000000 NEXTPNR_ROUTER2_MAX_STALL=250 \
        NEXTPNR_CRIT_DIST_EXP=1.0 \
        "$NEXTPNR" --chipdb "$CHIPDB" \
        --json "$d/am01_qmtech_top.fp.json" --xdc "$XDC" \
        --freq 133.33 --seed "$s" \
        --log "$d/route.log" > "$d/console" 2>&1
    f=$(grep -a "Max frequency for clock   'clk_h'" "$d/route.log" 2>/dev/null | tail -1 | sed -E "s/.*clk_h.: ([0-9.]+) MHz.*/\1/")
    i=$(grep -a "iter=" "$d/route.log" 2>/dev/null | tail -1 | sed -E "s/.*iter=([0-9]+).*/\1/")
    o=$(grep -a "iter=" "$d/route.log" 2>/dev/null | tail -1 | sed -E "s/.*overuse=([0-9]+).*/\1/")
    printf "%s\t$TAG\t%s\t%s\t%s\n" "$s" "${f:-FAIL}" "${i:--}" "${o:--}" >> "$RESULTS"
    tail -1 "$RESULTS"
done

echo
echo "=== $TAG vs 1-miner baseline (155.79 MHz median, 1x hashrate) -- $(date -Is) ==="
vals=$(awk -v v="$TAG" -F'\t' '$2==v && $3!="FAIL" {print $3}' "$RESULTS" | sort -n)
n=$(echo "$vals" | grep -c .)
if [ "$n" -gt 0 ]; then
    med=$(echo "$vals" | awk -v n="$n" 'NR==int((n+1)/2)')
    echo "  median: $med MHz (n=$n)"
    awk -v m="$med" 'BEGIN{printf "  relative hashrate vs baseline: %.2fx (1.333 x %s / 155.79)\n", (1.333*m)/155.79, m}'
fi
