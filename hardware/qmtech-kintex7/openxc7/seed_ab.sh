#!/usr/bin/env bash
# Multi-seed A/B for the BRAM output register.
#
# WHY THE SINGLE-SEED RUN WAS NOT ENOUGH
# --------------------------------------
# One seed gave base 104.22 vs outreg 85.16 MHz, and that difference is not
# interpretable: measured seed spread on this design is ~22 MHz, so a 19 MHz gap
# at n=1 is inside the noise.
#
# The mechanism itself is NOT in question. The critical-path reports show the
# register doing exactly what it was meant to:
#     baseline  2.1 ns  Source ...sbox47inst.mem.0.0.DOPADOP0
#     outreg    0.9 ns  Source ...sbox38inst.mem.0.0.DOBDO7
# and logic time fell 2.6 -> 1.6 ns. What killed that build was routing
# (7.0 -> 10.2 ns), dominated by a single 6.8 ns net spanning (107,99)->(43,249).
# Placement variance is worth ~2.5 ns here; the register is worth ~1 ns. So the
# effect is real but smaller than the noise, and only repetition separates them.
#
# WHAT THIS MEASURES
# ------------------
# Same two netlists, N seeds each, everything else identical. Compare the
# DISTRIBUTIONS, not any single pair -- median and best, with both columns
# visible so a wide spread is obvious rather than averaged away.
#
# Runs the two variants of a seed CONCURRENTLY (nextpnr peaks ~1.5 GB, and the
# box has ~11 GB with nothing else on it) but never more than one seed at a
# time. Two at once is safe; the memory exhaustion seen earlier came from an
# 10.6 GB yosys, not from routing.
set -uo pipefail
cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
SEEDS="${SEEDS:-1 2 4 5 6}"     # 3 already measured by route_ab.sh
RESULTS=seed_ab_results.tsv

echo $$ > .pid_seed_ab
trap 'rm -f .pid_seed_ab' EXIT

[ -f "$RESULTS" ] || printf "seed\tvariant\tclk_h_MHz\titers\toveruse\n" > "$RESULTS"

one () {   # one <seed> <variant> <netlist-dir>
    local seed="$1" var="$2" dir="$3"
    local out="seedrun/${var}_s${seed}"
    mkdir -p "$out"
    env NEXTPNR_ARC_MAX_VISIT=2000000 \
        NEXTPNR_ROUTER2_MAX_STALL=250 \
        NEXTPNR_CRIT_DIST_EXP=1.0 \
        "$NEXTPNR" --chipdb "$CHIPDB" \
        --json "$dir/am01_qmtech_top.fp.json" --xdc "$XDC" \
        --freq 133.33 --seed "$seed" \
        --log "$out/route.log" >"$out/console" 2>&1
    local f i o
    f=$(grep -a "Max frequency for clock   'clk_h'" "$out/route.log" 2>/dev/null \
        | tail -1 | sed -E 's/.*clk_h.: ([0-9.]+) MHz.*/\1/')
    i=$(grep -a "iter=" "$out/route.log" 2>/dev/null | tail -1 \
        | sed -E 's/.*iter=([0-9]+).*/\1/')
    o=$(grep -a "iter=" "$out/route.log" 2>/dev/null | tail -1 \
        | sed -E 's/.*overuse=([0-9]+).*/\1/')
    printf "%s\t%s\t%s\t%s\t%s\n" "$seed" "$var" "${f:-FAIL}" "${i:--}" "${o:--}" \
        >> "$RESULTS"
}

for s in $SEEDS; do
    echo "=== seed $s -- $(date -Is) ==="
    one "$s" base   out_ab_base   &
    P1=$!
    one "$s" outreg out_ab_outreg &
    P2=$!
    wait $P1 $P2
    tail -2 "$RESULTS"
done

echo
echo "=== ALL RESULTS -- $(date -Is) ==="
cat "$RESULTS"
echo
echo "=== summary (median / best per variant) ==="
for v in base outreg; do
    vals=$(awk -v v="$v" -F'\t' '$2==v && $3!="FAIL" {print $3}' "$RESULTS" | sort -n)
    n=$(echo "$vals" | grep -c .)
    [ "$n" -eq 0 ] && { printf "%-8s no results\n" "$v"; continue; }
    med=$(echo "$vals" | awk -v n="$n" 'NR==int((n+1)/2)')
    best=$(echo "$vals" | tail -1)
    printf "%-8s n=%-2s median %-8s best %-8s  all: %s\n" \
        "$v" "$n" "$med" "$best" "$(echo "$vals" | tr '\n' ' ')"
done
