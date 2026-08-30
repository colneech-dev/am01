#!/usr/bin/env bash
# Re-measure the winning configuration on the CORRECTED core.
#
# WHY EVERY e2nb NUMBER HAS TO BE RE-EARNED
# -----------------------------------------
# e2nb measured 158.23 MHz median with 5/5 seeds passing -- on a core that
# computed the wrong answer. tb_sched_equiv.v with +blocks=1 (one block in
# flight, so no interleaving and no read-phase effects, nothing but the
# arithmetic) showed the reference and --bram-out-reg cores disagreeing on a
# single block.
#
# The defect: full_round applies the round key COMBINATIONALLY after the sboxes
#     pbox0 -> apply_sboxes (clocked) -> pbox1 -> rotations -> apply_round_key
# so the key must be valid when the sbox output emerges, and get_round_key is
# itself clocked (a tap read at X yields a key at X+1). With a one-register
# sbox the tap is RoundCycles*i; --bram-out-reg makes the sbox TWO registers
# deep, so it must be RoundCycles*i + 1. The generator scaled the tap for the
# longer round but not for the deeper sbox, so every round key arrived one
# cycle early. Now RoundCycles()*(i+1)-2, which is byte-identical for the
# reference and 3*i+1 for the outreg variant.
#
# That changes the netlist, so the timing numbers are no longer valid. The
# PLACEMENT conclusions are unaffected -- wire-limited, relays beat register
# speed, the 2x2 -- because those are structural.
#
# CONFIGURATION UNDER TEST: e2nb, the winner of the 2x2.
#   odo_gen --bram-out-reg      3 cycles/round, second register present
#   extra_delay >= 1            gives extra_delay=2, the recirculation relay
#   BRAM_OUTREG=0               register stays in FABRIC (placeable, 0.1 ns)
#   BRAM_FP=1, BRAM_YBASE=40, CRIT_DIST=1.0
set -uo pipefail
cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7
REPO=/mnt/c/Users/Colin/Documents/GitHub/am01

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=$REPO/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
SEEDS="${SEEDS:-1 2 3 4 5}"
RESULTS=seed_ab_results.tsv
OUT="${OUT:-out_e2nb_fixed}"

echo $$ > .pid_e2nbfix
trap 'rm -f .pid_e2nbfix' EXIT

# Pinned sources, so a concurrent edit cannot skew this the way the wrapper
# change nearly did. Prints how far behind HEAD the pin is.
. ./rtl_sources.sh || exit 1

EPOCH=$(cat "$REPO/hdl/odocrypt/EPOCH")

# Rebuild the generator. It is gitignored, so a stale binary from before the
# round-key fix is entirely possible, and it would feed a ~2 h synthesis plus
# five routing runs with a core that computes wrong digests.
echo "=== rebuilding odo_gen ==="
make -s -C "$REPO/tools/odo_gen" odo_gen || { echo "odo_gen build FAILED"; exit 1; }

echo "=== regenerating the core, epoch $EPOCH ==="
if ! "$REPO/tools/odo_gen/odo_gen" "$EPOCH" 4 encrypt_4 --bram-out-reg \
        > gen/encrypt_outreg_fixed.v; then
    echo "odo_gen FAILED"; exit 1
fi
[ -s gen/encrypt_outreg_fixed.v ] || { echo "odo_gen produced nothing"; exit 1; }

# ASSERT the key taps rather than printing them for a human to eyeball.
# --bram-out-reg makes the sbox two registers deep, so the tap must be
# RoundCycles*i + 1 = 3*i+1: period[1], period[4], period[7], ...  The
# pre-fix generator emitted 3*i (period[0], [3], [6]) and produced a core
# that ran at full speed and computed the wrong answer. Printing that for
# review is exactly how it survived.
_taps=$(grep -oE "get_key[0-9]+\(clk, period\[[0-9]+\]" gen/encrypt_outreg_fixed.v \
        | grep -oE "[0-9]+\]$" | tr -d ']' | head -3 | tr '\n' ' ')
if [ "$_taps" != "1 4 7 " ]; then
    echo "KEY TAPS WRONG: got '$_taps', expected '1 4 7 '"
    echo "  The generator is not the fixed one -- refusing to spend hours on a"
    echo "  core that would compute wrong digests."
    exit 1
fi
echo "    key taps asserted: $_taps(3*i+1, correct for a 2-register sbox)"

# Re-synthesise if the netlist is missing, or older than ANY input.
#
# Watching only encrypt.v was not enough: re-baselining onto newer RTL changes
# the WRAPPER, not encrypt.v, so a stale netlist would have been routed against
# new sources -- precisely the failure this guard exists to catch. Testing mere
# existence (the original) was weaker still.
_need_synth=0
_netlist="$OUT/am01_qmtech_top.fp.json"
if [ ! -f "$_netlist" ]; then
    _need_synth=1
    echo "    no netlist -- will synthesise"
else
    for _src in gen/encrypt_outreg_fixed.v "${RTL_SRCS[@]}"; do
        if [ "$_src" -nt "$_netlist" ]; then
            _need_synth=1
            echo "    $(basename "$_src") is newer than the netlist -- will resynthesise"
            break
        fi
    done
fi

if [ "$_need_synth" = "1" ]; then
    echo
    echo "=== synthesis -- $(date -Is) ==="
    mkdir -p "$OUT"
    SRL=0 FREQ=133.33 DEFINES=NO_XADC BRAM_OUTREG=0 BRAM_FP=1 BRAM_YBASE=40 \
        XDC="$XDC" \
        bash build.sh am01_qmtech_top "$OUT" \
        "${RTL_SRCS[@]}" gen/encrypt_outreg_fixed.v > "$OUT/build.log" 2>&1
    echo "    build.sh exit $? -- $(date -Is)"
    grep -a "Max frequency for clock" "$OUT/am01_qmtech_top.pnr.log" 2>/dev/null | tail -2
fi

[ -f "$OUT/am01_qmtech_top.fp.json" ] || {
    echo "NO NETLIST -- tail:"; tail -20 "$OUT/build.log"; exit 1; }

for s in $SEEDS; do
    d="seedrun/e2nbfix_s${s}"; mkdir -p "$d"
    echo "=== e2nbfix seed $s -- $(date -Is) ==="
    env NEXTPNR_ARC_MAX_VISIT=2000000 NEXTPNR_ROUTER2_MAX_STALL=250 \
        NEXTPNR_CRIT_DIST_EXP=1.0 \
        "$NEXTPNR" --chipdb "$CHIPDB" \
        --json "$OUT/am01_qmtech_top.fp.json" --xdc "$XDC" \
        --freq 133.33 --seed "$s" \
        --log "$d/route.log" >"$d/console" 2>&1
    f=$(grep -a "Max frequency for clock   'clk_h'" "$d/route.log" 2>/dev/null | tail -1 | sed -E "s/.*clk_h.: ([0-9.]+) MHz.*/\1/")
    i=$(grep -a "iter=" "$d/route.log" 2>/dev/null | tail -1 | sed -E "s/.*iter=([0-9]+).*/\1/")
    o=$(grep -a "iter=" "$d/route.log" 2>/dev/null | tail -1 | sed -E "s/.*overuse=([0-9]+).*/\1/")
    printf "%s\te2nbfix\t%s\t%s\t%s\n" "$s" "${f:-FAIL}" "${i:--}" "${o:--}" >> "$RESULTS"
    tail -1 "$RESULTS"
done

echo
echo "=== e2nbfix vs the (invalid) e2nb numbers -- $(date -Is) ==="
for v in e2nb e2nbfix; do
    vals=$(awk -v v="$v" -F'\t' '$2==v && $3!="FAIL" {print $3}' "$RESULTS" | sort -n)
    n=$(echo "$vals" | grep -c .)
    [ "$n" -eq 0 ] && continue
    med=$(echo "$vals" | awk -v n="$n" 'NR==int((n+1)/2)')
    p=$(echo "$vals" | awk '$1+0>=133.33' | grep -c .)
    printf "  %-9s n=%-2s median %-8s pass %s/%s  all: %s\n" \
        "$v" "$n" "$med" "$p" "$n" "$(echo "$vals" | tr '\n' ' ')"
done
echo "  (e2nb was measured on the broken core and is retained only for comparison)"
