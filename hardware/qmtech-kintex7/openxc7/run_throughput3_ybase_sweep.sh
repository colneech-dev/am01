#!/usr/bin/env bash
# y-base sweep for the THROUGHPUT=3 (560 BRAM) layout, reusing the already-
# synthesised netlist (out_throughput3/am01_qmtech_top.json) so each
# candidate costs only a floorplan + route, not a multi-hour resynthesis.
#
# WHY: at BRAM_YBASE=40 (carried over unrefined from the 420-BRAM 1-miner
# layout), the fixed 6-column floorplan (--columns 0,1,2,3,4,5, build.sh's
# hardcoded default) packs 560 BRAM into 6x100=600 nominal slots (93% of
# the band) -- and routed timing came back marginal and seed-dependent
# (median 132.71 MHz, technically fails 133.33). See RESULTS.md
# "THROUGHPUT=3 alone" for the full seed table.
#
# The historical y-base sweep for the 420-BRAM case shows the relationship
# is NOT simple "more slack is better" -- y-base=0 (50% band-fill) measured
# WORSE (93.28 MHz) than y-base=40 (70% fill, 122.40 MHz), which beat
# y-base=53 (83% fill, 112.11 MHz). The driver was proximity to a specific
# favourable clock-region edge, not occupancy ratio -- so this sweeps
# candidates and lets ROUTED results decide, rather than reasoning from the
# occupancy number alone.
set -uo pipefail
cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
NETLIST=out_throughput3/am01_qmtech_top.json
RESULTS=seed_ab_results.tsv
SEED="${SEED:-1}"

echo $$ > .pid_ybase_sweep
trap 'rm -f .pid_ybase_sweep' EXIT

[ -f "$NETLIST" ] || { echo "NETLIST MISSING: $NETLIST -- run run_throughput3.sh first"; exit 1; }

for YB in ${YBASES:-0 20 53}; do
    d="seedrun/throughput3_yb${YB}_s${SEED}"
    mkdir -p "$d"
    TAG="throughput3_yb${YB}"

    echo "=== floorplan y-base=$YB -- $(date -Is) ==="
    python3 floorplan_brams.py "$NETLIST" "$d/am01_qmtech_top.fp.json" \
        --mode compact --columns 0,1,2,3,4,5 --y-base "$YB" \
        > "$d/floorplan.log" 2>&1 || { echo "  floorplan FAILED, see $d/floorplan.log"; continue; }
    tail -5 "$d/floorplan.log"

    echo "=== route y-base=$YB seed=$SEED -- $(date -Is) ==="
    env NEXTPNR_ARC_MAX_VISIT=2000000 NEXTPNR_ROUTER2_MAX_STALL=250 \
        NEXTPNR_CRIT_DIST_EXP=1.0 \
        "$NEXTPNR" --chipdb "$CHIPDB" \
        --json "$d/am01_qmtech_top.fp.json" --xdc "$XDC" \
        --freq 133.33 --seed "$SEED" \
        --log "$d/route.log" > "$d/console" 2>&1
    f=$(grep -a "Max frequency for clock   'clk_h'" "$d/route.log" 2>/dev/null | tail -1 | sed -E "s/.*clk_h.: ([0-9.]+) MHz.*/\1/")
    i=$(grep -a "iter=" "$d/route.log" 2>/dev/null | tail -1 | sed -E "s/.*iter=([0-9]+).*/\1/")
    o=$(grep -a "iter=" "$d/route.log" 2>/dev/null | tail -1 | sed -E "s/.*overuse=([0-9]+).*/\1/")
    printf "%s\t$TAG\t%s\t%s\t%s\n" "$SEED" "${f:-FAIL}" "${i:--}" "${o:--}" >> "$RESULTS"
    echo "  result: ${f:-FAIL} MHz (iter ${i:--}, overuse ${o:--})"
done

echo
echo "=== y-base sweep summary -- $(date -Is) ==="
echo "  y-base=40 (already measured, seed $SEED): 132.71 MHz FAIL"
for YB in ${YBASES:-0 20 53}; do
    grep "throughput3_yb${YB}" "$RESULTS" | tail -1
done
