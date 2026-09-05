#!/usr/bin/env bash
# THROUGHPUT=3: single wide miner, unrolling 21 -> 28, for 1.33x hashrate at
# the same Fmax. No LUTRAM conversion needed -- BRAM lands at 560/890 (63%),
# the same safe occupancy every single-miner build in this project has
# already routed at (baseline is 420/890, 47%). See RESULTS.md "THROUGHPUT
# is discretized, not a dial" for the sizing, and "Option A synthesis
# FAILED" for why THROUGHPUT=2 (2.00x, needs --lutram) is NOT attempted
# here -- that mechanism is confirmed broken on this yosys build.
#
# CONFIGURATION -- the "known good" recipe (run_e2nb_fixed.sh), unchanged
# except throughput and the miner.v swap:
#   odo_gen --bram-out-reg      3 cycles/round, second register present
#   BRAM_OUTREG=0               register stays in FABRIC (placeable, 0.1 ns)
#   BRAM_FP=1, BRAM_YBASE=40    Vivado-measured BRAM rows -- STARTING POINT
#                                ONLY. Calibrated for 420 BRAM; this design
#                                needs 560, so y-base may need retuning if
#                                the design spills past Y139. Watch the
#                                floorplan report for spills before
#                                trusting the routed number.
#   CRIT_DIST=1.0 (build.sh default, not overridden here)
set -uo pipefail
cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7
REPO=/mnt/c/Users/Colin/Documents/GitHub/am01

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=$REPO/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
SEEDS="${SEEDS:-1 2 3}"
RESULTS=seed_ab_results.tsv
OUT="${OUT:-out_throughput3}"
TAG="${TAG:-throughput3}"

echo $$ > .pid_throughput3
trap 'rm -f .pid_throughput3' EXIT

# Pinned sources, minus miner.v (THROUGHPUT=4), plus the THROUGHPUT=3
# variant from the working tree -- same pattern as run_option_a.sh.
. ./rtl_sources.sh || exit 1
SRCS=("$REPO/hdl/odocrypt/miner_t3.v")
for f in "${RTL_SRCS[@]}"; do
    case "$f" in *miner.v) continue ;; esac   # replaced by miner_t3.v
    SRCS+=("$f")
done

echo "    results tagged: $TAG"

EPOCH=$(cat "$REPO/hdl/odocrypt/EPOCH")

echo "=== rebuilding odo_gen ==="
make -s -C "$REPO/tools/odo_gen" odo_gen || { echo "odo_gen build FAILED"; exit 1; }

echo "=== regenerating the core, epoch $EPOCH, THROUGHPUT=3 (no lutram) ==="
if ! "$REPO/tools/odo_gen/odo_gen" "$EPOCH" 3 encrypt_3 --bram-out-reg \
        > gen/encrypt_throughput3.v; then
    echo "odo_gen FAILED"; exit 1
fi
[ -s gen/encrypt_throughput3.v ] || { echo "odo_gen produced nothing"; exit 1; }

# Same round-key-tap assertion as run_e2nb_fixed.sh/run_option_a.sh --
# RoundKeyTap(i) depends only on --bram-out-reg (RoundCycles=3), not on
# throughput, so the expected taps are unchanged: 1 4 7.
_taps=$(grep -oE "get_key[0-9]+\(clk, period\[[0-9]+\]" gen/encrypt_throughput3.v \
        | grep -oE "[0-9]+\]$" | tr -d ']' | head -3 | tr '\n' ' ')
if [ "$_taps" != "1 4 7 " ]; then
    echo "KEY TAPS WRONG: got '$_taps', expected '1 4 7 '"
    echo "  Refusing to spend hours on a core that would compute wrong digests."
    exit 1
fi
echo "    key taps asserted: $_taps(3*i+1, correct for a 2-register sbox)"

# No lutram assertion needed -- this build never sets --lutram, so all 10
# large-sbox module types stay ram_style=block. Sanity check anyway: expect
# 0 distributed, matching the block-only baseline behaviour.
_dist=$(grep -c 'ram_style = "distributed"' gen/encrypt_throughput3.v)
if [ "$_dist" != "0" ]; then
    echo "UNEXPECTED: $_dist distributed sboxes found, expected 0 (no --lutram passed)"
    exit 1
fi
echo "    confirmed: no distributed sboxes (all 10 types block RAM, as expected)"

_need_synth=0
_netlist="$OUT/am01_qmtech_top.fp.json"
if [ ! -f "$_netlist" ]; then
    _need_synth=1
    echo "    no netlist -- will synthesise"
else
    for _src in gen/encrypt_throughput3.v "${SRCS[@]}"; do
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
        "${SRCS[@]}" gen/encrypt_throughput3.v > "$OUT/build.log" 2>&1
    echo "    build.sh exit $? -- $(date -Is)"
    grep -a "Max frequency for clock" "$OUT/am01_qmtech_top.pnr.log" 2>/dev/null | tail -2
fi

[ -f "$OUT/am01_qmtech_top.fp.json" ] || {
    echo "NO NETLIST -- tail:"; tail -30 "$OUT/build.log"; exit 1; }

echo
echo "=== BRAM/LUT count check (expect ~560 BRAM, ~56k LUT) ==="
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
echo "=== THROUGHPUT=3 vs 1-miner baseline (155.79 MHz median, 1x hashrate) -- $(date -Is) ==="
vals=$(awk -v v="$TAG" -F'\t' '$2==v && $3!="FAIL" {print $3}' "$RESULTS" | sort -n)
n=$(echo "$vals" | grep -c .)
if [ "$n" -gt 0 ]; then
    med=$(echo "$vals" | awk -v n="$n" 'NR==int((n+1)/2)')
    echo "  THROUGHPUT=3 median: $med MHz (n=$n)"
    awk -v m="$med" 'BEGIN{printf "  relative hashrate vs baseline: %.2fx (1.333 x %s / 155.79)\n", (1.333*m)/155.79, m}'
fi
