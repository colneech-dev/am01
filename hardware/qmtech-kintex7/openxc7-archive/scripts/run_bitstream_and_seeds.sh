#!/usr/bin/env bash
# Bank the first passing bitstream, then find out how often it passes.
#
# WHAT HAPPENED
# -------------
# noabs seed 2 -- the --bram-out-reg RTL with the second register left in
# FABRIC, i.e. absorption NOT applied -- met timing for the first time:
#     Max frequency for clock 'clk_h': 137.49 MHz (PASS at 133.33 MHz)
# Verified clean: 0 errors, no SKIP_FAILED_ARCS, converged at iter 54 with
# overuse=0 unrouted=0 archfail=0, critical path 7.3 ns of a 7.5 ns budget.
#
# Two gaps that run leaves:
#   1. run_absorb_isolation.sh passes --log but NOT --fasm, so the passing
#      placement produced timing only. There is no bitstream.
#   2. n=3, and noabs spans 112.42-137.49. One seed passing is not the same as
#      the configuration passing.
#
# This closes both. Step 1 reproduces seed 2 through the FULL flow to a .bit.
# Step 2 extends the seed count so the pass rate is a measured number rather
# than an anecdote.
#
# ORDERING: strictly sequential. Step 1 runs build.sh (route + fasm2frames +
# xc7frames2bit); step 2 routes; step 3 hands back to e2. Nothing overlaps --
# yosys peaks over 10 GB on an 11 GB box.
set -uo pipefail
cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7
REPO=/mnt/c/Users/Colin/Documents/GitHub/am01

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=$REPO/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
RESULTS=seed_ab_results.tsv
MORE_SEEDS="${MORE_SEEDS:-6 7 8 9 10 11}"

echo $$ > .pid_bits
trap 'rm -f .pid_bits' EXIT

for f in .pid_absiso .pid_seed_ab; do
    [ -f "$f" ] || continue
    P=$(cat "$f")
    echo "waiting for $f pid $P -- $(date -Is)"
    while kill -0 "$P" 2>/dev/null; do sleep 60; done
done
echo "clear to run -- $(date -Is)"

# ---------------------------------------------------------------- step 1
# Reproduce seed 2 end to end. REUSE_JSON adopts the already-synthesised noabs
# netlist (the PRE-floorplan one, so build.sh re-applies the same floorplan),
# skipping a ~2 h synthesis. build.sh's router defaults already match what the
# isolation run used: ARC_MAX_VISIT=2000000, MAX_STALL=250, CRIT_DIST=1.0.
echo
echo "=== [1/3] bitstream from noabs seed 2 -- $(date -Is) ==="
OUTB=out_pass_s2
mkdir -p "$OUTB"
SRL=0 FREQ=133.33 SEED=2 BRAM_FP=1 BRAM_YBASE=40 BRAM_OUTREG=0 \
    XDC="$XDC" REUSE_JSON=out_ab_noabs/am01_qmtech_top.json \
    bash build.sh am01_qmtech_top "$OUTB" \
    "$REPO/hardware/qmtech-kintex7/hdl/am01_qmtech_top_nm1.v" \
    > "$OUTB/build.log" 2>&1
rc=$?
echo "    build.sh exit $rc -- $(date -Is)"
grep -a "Max frequency for clock" "$OUTB/am01_qmtech_top.pnr.log" 2>/dev/null | tail -2

if [ -f "$OUTB/am01_qmtech_top.bit" ]; then
    echo "    BITSTREAM: $(ls -l "$OUTB/am01_qmtech_top.bit" | awk '{print $5}') bytes"
    file "$OUTB/am01_qmtech_top.bit" | cut -c1-120
else
    echo "    NO BITSTREAM -- tail of build log:"
    tail -25 "$OUTB/build.log"
fi

# ---------------------------------------------------------------- step 2
echo
echo "=== [2/3] more noabs seeds: $MORE_SEEDS -- $(date -Is) ==="
for s in $MORE_SEEDS; do
    d="seedrun/noabs_s${s}"; mkdir -p "$d"
    echo "--- noabs seed $s -- $(date -Is) ---"
    env NEXTPNR_ARC_MAX_VISIT=2000000 NEXTPNR_ROUTER2_MAX_STALL=250 \
        NEXTPNR_CRIT_DIST_EXP=1.0 \
        "$NEXTPNR" --chipdb "$CHIPDB" \
        --json out_ab_noabs/am01_qmtech_top.fp.json --xdc "$XDC" \
        --freq 133.33 --seed "$s" \
        --log "$d/route.log" >"$d/console" 2>&1
    f=$(grep -a "Max frequency for clock   'clk_h'" "$d/route.log" 2>/dev/null | tail -1 | sed -E "s/.*clk_h.: ([0-9.]+) MHz.*/\1/")
    i=$(grep -a "iter=" "$d/route.log" 2>/dev/null | tail -1 | sed -E "s/.*iter=([0-9]+).*/\1/")
    o=$(grep -a "iter=" "$d/route.log" 2>/dev/null | tail -1 | sed -E "s/.*overuse=([0-9]+).*/\1/")
    printf "%s\tnoabs\t%s\t%s\t%s\n" "$s" "${f:-FAIL}" "${i:--}" "${o:--}" >> "$RESULTS"
    tail -1 "$RESULTS"
done

echo
echo "=== noabs pass rate at 133.33 MHz -- $(date -Is) ==="
awk -F'\t' '$2=="noabs" && $3!="FAIL" {n++; if ($3+0 >= 133.33) p++}
     END {printf "  %d of %d seeds PASS (%.0f%%)\n", p+0, n+0, (n?100*p/n:0)}' "$RESULTS"
for v in base noabs outreg; do
    vals=$(awk -v v="$v" -F'\t' '$2==v && $3!="FAIL" {print $3}' "$RESULTS" | sort -n)
    n=$(echo "$vals" | grep -c .)
    [ "$n" -eq 0 ] && continue
    med=$(echo "$vals" | awk -v n="$n" 'NR==int((n+1)/2)')
    printf "  %-8s n=%-2s median %-8s  all: %s\n" "$v" "$n" "$med" "$(echo "$vals" | tr '\n' ' ')"
done

# ---------------------------------------------------------------- step 3
echo
echo "=== [3/3] handing back to e2 -- $(date -Is) ==="
setsid nohup bash run_e2.sh > e2.console 2>&1 < /dev/null &
echo "    e2 relaunched"
