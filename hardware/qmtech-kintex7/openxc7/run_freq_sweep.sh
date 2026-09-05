#!/usr/bin/env bash
# Sweep the TIMING CONSTRAINT, not the RTL.
#
# WHY THIS EXISTS
# ---------------
# hdl/clk_gen_hash.v was speed-bumped on 2026-09-01 from CLKFBOUT_MULT 16 to
# 19, taking clk_h from 133.33 to 158.33 MHz (that bump is where the shipping
# ~80 MH/s comes from: 2 miners * 158.33 / 4 = 79.2). The openXC7 flow did not
# follow, because rtl_sources.sh pins the RTL at afa4b22 (2026-08-30), which
# predates it -- gen/rtl_pinned/clk_gen_hash.v is still MULT 16.
#
# So FREQ=133.33 is CORRECT for the pinned core; this is staleness, not a
# sign-off bug. But it means every openXC7 seed number so far was graded
# against a target 25 MHz below what master actually needs to hit. Of the
# e2nbfix baseline seeds -- 145.14 152.44 155.79 174.98 197.43 -- only two
# would clear 158.33.
#
# The timing question does not need the MMCM change: nextpnr times clk_h
# against --freq regardless of the MMCM parameters (see build.sh, "FREQ has no
# safe default" -- the XDC create_clock does not reach clk_h, so --freq IS the
# constraint for every domain). Swapping the MMCM parameters only matters for
# what the finished bitstream actually runs at, and is a one-line change once
# a frequency is known to close.
#
# The hope is not merely re-grading. --freq drives the timing-driven placer and
# the router's criticality, so ASKING for more can DELIVER more: the baseline's
# 145-197 was achieved while only being asked for 133.33.
#
# Reuses an existing netlist, so no synthesis (~3 h) is repeated -- each seed
# is a route only, roughly 20-30 min.
#
#   FREQ=158.33 SEEDS="1 2 3 4 5" ./run_freq_sweep.sh
#
set -uo pipefail
cd "$(dirname "$0")"
REPO=$(cd ../../.. && pwd)

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=$REPO/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
RESULTS=seed_ab_results.tsv

# out_e2nbfix_v15 is the baseline whose seeds produced 145.14 .. 197.43. Using
# the SAME netlist is what makes --freq the only variable.
OUT="${OUT:-out_e2nbfix_v15}"
FREQ="${FREQ:?set FREQ, e.g. FREQ=158.33}"
SEEDS="${SEEDS:-1 2 3 4 5}"
TAG="${TAG:-freq${FREQ}}"

[ -f "$OUT/am01_qmtech_top.fp.json" ] || { echo "no netlist in $OUT"; exit 1; }

echo "=== constraint sweep: FREQ=$FREQ  netlist=$OUT  seeds='$SEEDS' ==="
echo "    tag: $TAG"
echo

for s in $SEEDS; do
    d="seedrun/${TAG}_s${s}"; mkdir -p "$d"
    echo "=== FREQ=$FREQ seed $s -- $(date -Is) ==="
    env NEXTPNR_ARC_MAX_VISIT=2000000 NEXTPNR_ROUTER2_MAX_STALL=250 \
        NEXTPNR_CRIT_DIST_EXP=1.0 \
        "$NEXTPNR" --chipdb "$CHIPDB" \
        --json "$OUT/am01_qmtech_top.fp.json" --xdc "$XDC" \
        --freq "$FREQ" --seed "$s" \
        --log "$d/route.log" >"$d/console" 2>&1

    # Take the Fmax that FOLLOWS the final iter= line. nextpnr prints a
    # pre-route SA estimate earlier in the log; quoting that as a result is
    # the mistake that made the premix v1 run look like it had a number.
    last_iter_line=$(grep -an "iter=" "$d/route.log" 2>/dev/null | tail -1)
    li=${last_iter_line%%:*}
    o=$(echo "$last_iter_line" | sed -E "s/.*overuse=([0-9]+).*/\1/")
    f=$(awk -F: -v li="${li:-0}" 'NR>li && /Max frequency for clock   .clk_h./ {
            line=$0 } END { if (line=="") print "";
            else { sub(/.*clk_h.: /, "", line); sub(/ MHz.*/, "", line); print line } }' \
        "$d/route.log")
    i=$(echo "$last_iter_line" | sed -E "s/.*iter=([0-9]+).*/\1/")
    [ "${o:-1}" = "0" ] || f="UNCONVERGED"
    printf "%s\t$TAG\t%s\t%s\t%s\n" "$s" "${f:-FAIL}" "${i:--}" "${o:--}" >> "$RESULTS"
    tail -1 "$RESULTS"
done

echo
echo "=== FREQ=$FREQ summary -- $(date -Is) ==="
vals=$(awk -v v="$TAG" -F'\t' '$2==v && $3!="FAIL" && $3!="UNCONVERGED" {print $3}' "$RESULTS" | sort -n)
n=$(echo "$vals" | grep -c .)
if [ "$n" -gt 0 ]; then
    med=$(echo "$vals" | awk -v n="$n" 'NR==int((n+1)/2)')
    p=$(echo "$vals" | awk -v F="$FREQ" '$1+0>=F+0' | grep -c .)
    printf "  n=%-2s median %-8s CLOSING at %s MHz: %s/%s  all: %s\n" \
        "$n" "$med" "$FREQ" "$p" "$n" "$(echo "$vals" | tr '\n' ' ')"
else
    echo "  no converged seeds"
fi
