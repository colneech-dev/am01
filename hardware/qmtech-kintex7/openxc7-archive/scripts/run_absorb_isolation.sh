#!/usr/bin/env bash
# Isolate what the BRAM output register absorption is actually worth.
#
# WHY THE FIRST A/B COULD NOT ANSWER THIS
# ---------------------------------------
# seed_ab.sh compared baseline RTL against outreg RTL + absorption, and outreg
# lost every seed by 25-35 MHz with no distribution overlap:
#     base    104.22 111.54 114.81 117.44 120.19
#     outreg   81.49  82.29  83.11  83.32  85.16
# That is decisive about the PAIR, but it cannot attribute the loss, because
# `odo_gen --bram-out-reg` changes TWO things at once:
#   1. the BRAM output register  (what we wanted to measure)
#   2. the RTL schedule -- 2 -> 3 cycles per round, which moves extra_delay
#      1 -> 0 and the state pipeline 22 -> 21 stages
# Those extra_delay stages are registered pass-throughs
# (`assign next[i+unrolling] = state[i+unrolling]`) -- relay points that break
# long paths. Losing one is a plausible seed-independent penalty with nothing to
# do with the BRAM, and outreg's spread being 3.7 MHz against base's 16 MHz says
# whatever binds it IS systematic rather than placement luck.
#
# Meanwhile the register itself demonstrably worked, in the critical path:
#     baseline  2.1 ns  Source ...sbox47inst.mem.0.0.DOPADOP0
#     outreg    0.9 ns  Source ...sbox38inst.mem.0.0.DOBDO7
# with logic time 2.6 -> 1.6 ns.
#
# WHAT THIS MEASURES
# ------------------
# The SAME outreg RTL, with and without absorption. Identical schedule on both
# sides, so absorption is the only variable. If absorption is a win, the
# no-absorb side should be slower than the 81-85 MHz already recorded; if the
# 3-cycle schedule is the whole story, both sides land together and the register
# is worth having only via some other route that leaves the schedule alone.
set -uo pipefail
cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7
REPO=/mnt/c/Users/Colin/Documents/GitHub/am01

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=$REPO/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
SEEDS="${SEEDS:-1 2 3 4 5}"
RESULTS=seed_ab_results.tsv
OUT=out_ab_noabs

echo $$ > .pid_absiso
trap 'rm -f .pid_absiso' EXIT

# Wait for the seed sweep: yosys peaks ~10.6 GB and must not overlap routing.
if [ -f .pid_seed_ab ]; then
    P=$(cat .pid_seed_ab)
    echo "waiting for seed sweep pid $P -- $(date -Is)"
    while kill -0 "$P" 2>/dev/null; do sleep 60; done
    echo "seed sweep finished -- $(date -Is)"
fi

# Synthesise the outreg RTL with absorption OFF. build.sh now also preserves
# <top>.preabsorb.json, but this netlist never had absorption applied at all,
# which is the cleaner control.
if [ ! -f "$OUT/am01_qmtech_top.fp.json" ]; then
    echo "=== synthesis, absorption OFF -- $(date -Is) ==="
    mkdir -p "$OUT"
    SRL=0 FREQ=133.33 DEFINES=NO_XADC BRAM_OUTREG=0 BRAM_FP=1 BRAM_YBASE=40 \
        XDC="$XDC" \
        bash build.sh am01_qmtech_top "$OUT" \
        "$REPO/hardware/qmtech-kintex7/hdl/am01_qmtech_top_nm1.v" \
        "$REPO/hardware/qmtech-kintex7/hdl/clk_gen_hash.v" \
        "$REPO/hardware/qmtech-kintex7/hdl/odocrypt_gpio_wrapper.v" \
        "$REPO/hdl/odocrypt/atomminer_misc.v" \
        "$REPO/hdl/odocrypt/keccak800.v" \
        "$REPO/hdl/odocrypt/miner.v" \
        gen/encrypt_outreg.v > "$OUT/build.log" 2>&1
    echo "    build.sh exit $? -- $(date -Is)"
fi

if [ ! -f "$OUT/am01_qmtech_top.fp.json" ]; then
    echo "NO NETLIST -- synthesis failed; tail:"; tail -20 "$OUT/build.log"; exit 1
fi

# Sanity: this netlist must have NO output register, or the control is not one.
n=$(grep -ao '"DOA_REG": 1' "$OUT/am01_qmtech_top.fp.json" | wc -l)
echo "    DOA_REG=1 count in control netlist: $n (expect 0)"
[ "$n" -eq 0 ] || echo "    WARNING: control netlist is NOT absorption-free"

for s in $SEEDS; do
    d="seedrun/noabs_s${s}"
    mkdir -p "$d"
    echo "=== noabs seed $s -- $(date -Is) ==="
    env NEXTPNR_ARC_MAX_VISIT=2000000 NEXTPNR_ROUTER2_MAX_STALL=250 \
        NEXTPNR_CRIT_DIST_EXP=1.0 \
        "$NEXTPNR" --chipdb "$CHIPDB" \
        --json "$OUT/am01_qmtech_top.fp.json" --xdc "$XDC" \
        --freq 133.33 --seed "$s" \
        --log "$d/route.log" >"$d/console" 2>&1
    f=$(grep -a "Max frequency for clock   'clk_h'" "$d/route.log" 2>/dev/null \
        | tail -1 | sed -E "s/.*clk_h.: ([0-9.]+) MHz.*/\1/")
    i=$(grep -a "iter=" "$d/route.log" 2>/dev/null | tail -1 | sed -E "s/.*iter=([0-9]+).*/\1/")
    o=$(grep -a "iter=" "$d/route.log" 2>/dev/null | tail -1 | sed -E "s/.*overuse=([0-9]+).*/\1/")
    printf "%s\tnoabs\t%s\t%s\t%s\n" "$s" "${f:-FAIL}" "${i:--}" "${o:--}" >> "$RESULTS"
    tail -1 "$RESULTS"
done

echo
echo "=== ABSORPTION ISOLATED -- $(date -Is) ==="
for v in base outreg noabs; do
    vals=$(awk -v v="$v" -F'\t' '$2==v && $3!="FAIL" {print $3}' "$RESULTS" | sort -n)
    n=$(echo "$vals" | grep -c .)
    [ "$n" -eq 0 ] && continue
    med=$(echo "$vals" | awk -v n="$n" 'NR==int((n+1)/2)')
    printf "%-8s n=%-2s median %-8s  all: %s\n" "$v" "$n" "$med" "$(echo "$vals" | tr '\n' ' ')"
done
echo
echo "outreg vs noabs isolates the ABSORPTION (same schedule both sides)."
echo "base vs noabs isolates the 3-CYCLE SCHEDULE (no absorption either side)."
