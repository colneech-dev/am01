#!/usr/bin/env bash
# Option A: single WIDE miner, THROUGHPUT=2 (unrolling 21 -> 42, so 2.00x
# hashrate at the same Fmax), with 3 of 10 large S-boxes converted to
# distributed RAM (--lutram=3) to bring BRAM back to a comfortable 63%
# occupancy instead of the 94% that plain THROUGHPUT=2 would need -- the
# same wall that ate the whole 2026-08-31/09-01 2-miner routing campaign.
# See RESULTS.md "Option A" for the sizing and the reasoning.
#
# Sized (2026-09-01): BRAM 560/890 (63%), LUT ~208k/407k (51%, unverified --
# first real design at this LUT occupancy). Functional equivalence of
# --lutram=3 vs --lutram=0 verified separately: sim/run_lutram_equiv.sh.
#
# CONFIGURATION -- the "known good" recipe (run_e2nb_fixed.sh), unchanged
# except throughput/lutram and the miner.v swap:
#   odo_gen --bram-out-reg      3 cycles/round, second register present
#   BRAM_OUTREG=0               register stays in FABRIC (placeable, 0.1 ns)
#   BRAM_FP=1, BRAM_YBASE=40    Vivado-measured BRAM rows -- STARTING POINT
#                                ONLY. Calibrated for 420 BRAM; this design
#                                needs 560, so y-base may need retuning if
#                                the design spills past Y139. Watch the
#                                floorplan report for spills before
#                                trusting the routed number.
#   CRIT_DIST=1.0 (build.sh default, not overridden here, matching
#                  run_e2nb_fixed.sh exactly)
#
# miner_t2.v (hdl/odocrypt/miner_t2.v, THROUGHPUT=2, encrypt_2encrypt)
# REPLACES the pinned miner.v (THROUGHPUT=4, encrypt_4encrypt) in the
# source list -- everything else stays on the same pin as every other
# measurement this session, so the comparison attributes cleanly to the
# throughput/lutram change alone.
set -uo pipefail
cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7
REPO=/mnt/c/Users/Colin/Documents/GitHub/am01

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=$REPO/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
SEEDS="${SEEDS:-1 2 3}"
LUTRAM="${LUTRAM:-3}"
RESULTS=seed_ab_results.tsv
OUT="${OUT:-out_option_a}"
TAG="${TAG:-optionA_t2_lutram${LUTRAM}}"

echo $$ > .pid_option_a
trap 'rm -f .pid_option_a' EXIT

# Pinned sources, minus miner.v (THROUGHPUT=4), plus the THROUGHPUT=2
# variant from the working tree. Not part of the pin because it is new --
# see its header comment for why it must never be compiled alongside the
# real miner.v.
. ./rtl_sources.sh || exit 1
SRCS=("$REPO/hdl/odocrypt/miner_t2.v")
for f in "${RTL_SRCS[@]}"; do
    case "$f" in *miner.v) continue ;; esac   # replaced by miner_t2.v
    SRCS+=("$f")
done

echo "    results tagged: $TAG"

EPOCH=$(cat "$REPO/hdl/odocrypt/EPOCH")

echo "=== rebuilding odo_gen ==="
make -s -C "$REPO/tools/odo_gen" odo_gen || { echo "odo_gen build FAILED"; exit 1; }

echo "=== regenerating the core, epoch $EPOCH, THROUGHPUT=2 --lutram=$LUTRAM ==="
if ! "$REPO/tools/odo_gen/odo_gen" "$EPOCH" 2 encrypt_2 --bram-out-reg --lutram="$LUTRAM" \
        > gen/encrypt_option_a.v; then
    echo "odo_gen FAILED"; exit 1
fi
[ -s gen/encrypt_option_a.v ] || { echo "odo_gen produced nothing"; exit 1; }

# Same round-key-tap assertion as run_e2nb_fixed.sh. RoundKeyTap(i) =
# RoundCycles()*(i+1)-2 depends only on --bram-out-reg (RoundCycles=3), not
# on throughput/unrolling, so the expected taps are unchanged: 1 4 7.
_taps=$(grep -oE "get_key[0-9]+\(clk, period\[[0-9]+\]" gen/encrypt_option_a.v \
        | grep -oE "[0-9]+\]$" | tr -d ']' | head -3 | tr '\n' ' ')
if [ "$_taps" != "1 4 7 " ]; then
    echo "KEY TAPS WRONG: got '$_taps', expected '1 4 7 '"
    echo "  Refusing to spend hours on a core that would compute wrong digests."
    exit 1
fi
echo "    key taps asserted: $_taps(3*i+1, correct for a 2-register sbox)"

# Sanity-check the lutram split landed as expected: LUTRAM of 10 module
# types distributed, the rest block.
_dist=$(grep -c 'ram_style = "distributed"' gen/encrypt_option_a.v)
_block=$(grep -c 'ram_style = "block"' gen/encrypt_option_a.v)
if [ "$_dist" != "$LUTRAM" ] || [ "$_block" != "$((10-LUTRAM))" ]; then
    echo "LUTRAM SPLIT WRONG: distributed=$_dist block=$_block, expected $LUTRAM/$((10-LUTRAM))"
    exit 1
fi
echo "    lutram split asserted: $_dist distributed, $_block block (of 10 large-sbox types)"

_need_synth=0
_netlist="$OUT/am01_qmtech_top.fp.json"
if [ ! -f "$_netlist" ]; then
    _need_synth=1
    echo "    no netlist -- will synthesise"
else
    for _src in gen/encrypt_option_a.v "${SRCS[@]}"; do
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
        "${SRCS[@]}" gen/encrypt_option_a.v > "$OUT/build.log" 2>&1
    echo "    build.sh exit $? -- $(date -Is)"
    grep -a "Max frequency for clock" "$OUT/am01_qmtech_top.pnr.log" 2>/dev/null | tail -2
fi

[ -f "$OUT/am01_qmtech_top.fp.json" ] || {
    echo "NO NETLIST -- tail:"; tail -30 "$OUT/build.log"; exit 1; }

echo
echo "=== BRAM/LUT count check (expect ~560 BRAM) ==="
python3 - "$OUT/am01_qmtech_top.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))["modules"]["am01_qmtech_top"]
bram = sum(1 for c in m["cells"].values() if c["type"] == "RAMB18E1")
luts = sum(1 for c in m["cells"].values() if c["type"].startswith("LUT"))
print("    RAMB18E1 cells: %d (%.1f%% of 890)" % (bram, 100.0*bram/890))
print("    LUT cells: %d (%.1f%% of 407600)" % (luts, 100.0*luts/407600))
PY

for s in $SEEDS; do
    d="seedrun/${TAG}_s${s}"; mkdir -p "$d"
    echo "=== $TAG seed $s -- $(date -Is) ==="
    env NEXTPNR_ARC_MAX_VISIT=2000000 NEXTPNR_ROUTER2_MAX_STALL=250 \
        NEXTPNR_CRIT_DIST_EXP=1.0 \
        "$NEXTPNR" --chipdb "$CHIPDB" \
        --json "$OUT/am01_qmtech_top.fp.json" --xdc "$XDC" \
        --freq 133.33 --seed "$s" \
        --log "$d/route.log" >"$d/console" 2>&1
    f=$(grep -a "Max frequency for clock   'clk_h'" "$d/route.log" 2>/dev/null | tail -1 | sed -E "s/.*clk_h.: ([0-9.]+) MHz.*/\1/")
    i=$(grep -a "iter=" "$d/route.log" 2>/dev/null | tail -1 | sed -E "s/.*iter=([0-9]+).*/\1/")
    o=$(grep -a "iter=" "$d/route.log" 2>/dev/null | tail -1 | sed -E "s/.*overuse=([0-9]+).*/\1/")
    printf "%s\t$TAG\t%s\t%s\t%s\n" "$s" "${f:-FAIL}" "${i:--}" "${o:--}" >> "$RESULTS"
    tail -1 "$RESULTS"
done

echo
echo "=== Option A vs 1-miner baseline (155.79 MHz median, 1x hashrate) -- $(date -Is) ==="
vals=$(awk -v v="$TAG" -F'\t' '$2==v && $3!="FAIL" {print $3}' "$RESULTS" | sort -n)
n=$(echo "$vals" | grep -c .)
if [ "$n" -gt 0 ]; then
    med=$(echo "$vals" | awk -v n="$n" 'NR==int((n+1)/2)')
    echo "  Option A median: $med MHz (n=$n)"
    awk -v m="$med" 'BEGIN{printf "  relative hashrate vs baseline: %.2fx (2 x %s / 155.79)\n", (2*m)/155.79, m}'
fi
