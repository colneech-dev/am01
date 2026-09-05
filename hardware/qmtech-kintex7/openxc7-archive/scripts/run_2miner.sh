#!/usr/bin/env bash
# Two miners: the biggest available win, and the first test of the miner-aware
# floorplan.
#
# WHY THIS MATTERS MORE THAN Fmax
# -------------------------------
# Hashrate scales as NUM_MINERS x Fmax. Two miners is +100%; the entire Fmax
# campaign was +16% over target. Two miners beats one even at a clock that
# FAILS the current target:
#
#     1 miner  @ 155.79 (current)      1.00x
#     2 miners @ 133.33 (just passes)  1.71x
#     2 miners @ 100    (fails target) 1.28x
#
# So the question is how much is gained, not whether it works.
#
# WHAT CHANGES, AND WHAT DOES NOT
# -------------------------------
# am01_qmtech_top_nm2.v is am01_qmtech_top_nm1.v with NUM_MINERS(2) and nothing
# else, so a comparison against the single-miner numbers attributes cleanly to
# miner count rather than to the display path or anything else.
#
# THE FLOORPLAN LOSES ITS BEST LEVER, and that is priced in rather than hidden:
# y-base 40 was worth +29 MHz, the single largest win in this work, and it is
# only possible because ONE miner uses half the block RAM. Two miners need 840
# of 890 sites, so the layout must start at y-base 0 and use every column
# including 6 (which stops at Y59). Expect a real loss here; the question is
# whether it is smaller than the 2x.
#
#     cols 0-4  140 sites each     col 5  130 (ten gaps)     col 6  60
#     cols 0-5 = 830 < 840, so column 6 is mandatory
#
# floorplan_brams.py partitions BY SITE COUNT, giving miner 0 columns 0-2 (420
# exactly) and miner 1 columns 3-6. Verified on the single-miner case first:
# the layout it emits is byte-identical to the historical one.
set -uo pipefail
cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7
REPO=/mnt/c/Users/Colin/Documents/GitHub/am01

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=$REPO/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
SEEDS="${SEEDS:-1 2 3}"
RESULTS=seed_ab_results.tsv
OUT=out_2miner
TAG=2miner

echo $$ > .pid_2miner
trap 'rm -f .pid_2miner' EXIT

. ./rtl_sources.sh || exit 1

EPOCH=$(cat "$REPO/hdl/odocrypt/EPOCH")
echo "=== rebuilding odo_gen ==="
make -s -C "$REPO/tools/odo_gen" odo_gen || { echo "odo_gen build FAILED"; exit 1; }

echo "=== regenerating the core, epoch $EPOCH ==="
"$REPO/tools/odo_gen/odo_gen" "$EPOCH" 4 encrypt_4 --bram-out-reg \
    > gen/encrypt_2miner.v || { echo "odo_gen FAILED"; exit 1; }
_taps=$(grep -oE "get_key[0-9]+\(clk, period\[[0-9]+\]" gen/encrypt_2miner.v \
        | grep -oE "[0-9]+\]$" | tr -d ']' | head -3 | tr '\n' ' ')
[ "$_taps" = "1 4 7 " ] || { echo "KEY TAPS WRONG: '$_taps' -- refusing"; exit 1; }
echo "    key taps asserted: $_taps"

# The 2-miner top, and the pinned wrapper/miner sources. nm2 is NOT in
# rtl_sources.sh's pinned set (it is new), so take it from the working tree and
# say so -- if it changes, this measurement is not comparable.
NM2="$REPO/hardware/qmtech-kintex7/hdl/am01_qmtech_top_nm2.v"
[ -f "$NM2" ] || { echo "missing $NM2"; exit 1; }
SRCS=("$NM2")
for f in "${RTL_SRCS[@]}"; do
    case "$f" in *am01_qmtech_top_nm1.v) continue ;; esac   # replaced by nm2
    SRCS+=("$f")
done

if [ ! -f "$OUT/am01_qmtech_top.fp.json" ]; then
    echo
    echo "=== synthesis (NUM_MINERS=2) -- $(date -Is) ==="
    mkdir -p "$OUT"
    # BRAM_FP=0: build.sh's floorplan call hardcodes y-base and columns for one
    # miner. Floorplan is applied separately below with the 2-miner geometry.
    SRL=0 FREQ=133.33 DEFINES=NO_XADC BRAM_OUTREG=0 BRAM_FP=0 \
        XDC="$XDC" \
        bash build.sh am01_qmtech_top "$OUT" "${SRCS[@]}" gen/encrypt_2miner.v \
        > "$OUT/build.log" 2>&1
    echo "    build.sh exit $? -- $(date -Is)"
    grep -aE "RAMB18E1:|Max frequency for clock" "$OUT/am01_qmtech_top.pnr.log" 2>/dev/null | tail -3
fi

[ -f "$OUT/am01_qmtech_top.json" ] || {
    echo "NO NETLIST -- tail:"; tail -25 "$OUT/build.log"; exit 1; }

echo
echo "=== BRAM count check (expect 840) ==="
python3 - "$OUT/am01_qmtech_top.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))["modules"]["am01_qmtech_top"]
n = sum(1 for c in m["cells"].values() if c["type"] == "RAMB18E1")
print("    RAMB18E1 cells: %d" % n)
sys.exit(0 if n == 840 else 1)
PY
[ $? -eq 0 ] || { echo "    NOT 840 -- the second miner did not instantiate"; exit 1; }

echo
echo "=== floorplan (2 miners: y-base 0, all 7 columns) -- $(date -Is) ==="
python3 floorplan_brams.py "$OUT/am01_qmtech_top.json" "$OUT/am01_qmtech_top.fp.json" \
    --mode compact --columns 0,1,2,3,4,5,6 --y-base 0 || exit 1

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
echo "=== 2 miners vs 1, in HASHRATE terms -- $(date -Is) ==="
one=$(awk -F'\t' '$2=="e2nbfix_v15" && $3!="FAIL"{print $3}' "$RESULTS" | sort -n | awk 'NR==3')
two=$(awk -F'\t' -v t="$TAG" '$2==t && $3!="FAIL"{print $3}' "$RESULTS" | sort -n | awk 'NR==2')
echo "  1 miner  median ${one:-?} MHz"
echo "  2 miners median ${two:-?} MHz"
[ -n "$one" ] && [ -n "$two" ] && awk -v a="$one" -v b="$two" \
    'BEGIN{printf "  relative hashrate: %.2fx  (2*%s / 1*%s)\n", (2*b)/a, b, a}'
