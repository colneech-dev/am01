#!/usr/bin/env bash
# Test the actual candidate: BRAM output register WITH the recirculation relay.
#
# THE DIAGNOSIS THIS TESTS
# ------------------------
# The first outreg build lost 31 MHz. That was not the BRAM register: across six
# seeds the register worked perfectly and identically (BRAM source delay
# 2.1 -> 0.9 ns every time), while the critical path ended at `state[0]` on
# EVERY outreg seed and at a mid-pipeline `next[10..16]` on every base seed.
#
# `state[0]` is the recirculation register. odo_gen's extra_delay stages are
# REGISTERED pass-throughs sitting in that feedback path, and the search started
# at 0 and took the first coprime value, so whether one existed was luck:
#     base   gcd(4, 2*21+0)=2 -> bumped to 1   (relay present)
#     outreg gcd(4, 3*21+0)=1 -> accepted 0    (relay absent)
# With no relay, the feedback from the last round to state[0] crosses the whole
# floorplan combinationally -- a measured 6.8 ns net, (107,99) -> (43,249).
#
# odo_gen now starts the search at 1, giving extra_delay=2 for the outreg
# schedule (state[22:0], period[64:0]) and leaving base byte-identical.
#
# So this build has BOTH the output register AND the relay. If the diagnosis is
# right it should beat base's 104-120 MHz; if it merely returns to base's range,
# the register is neutral; if it stays at 81-85, the diagnosis is wrong and the
# 3-cycle schedule is bad for some other reason.
set -uo pipefail
cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7
REPO=/mnt/c/Users/Colin/Documents/GitHub/am01

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=$REPO/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
SEEDS="${SEEDS:-1 2 3 4 5}"
RESULTS=seed_ab_results.tsv
OUT=out_ab_e2nb

echo $$ > .pid_e2nb
trap 'rm -f .pid_e2nb' EXIT

# One heavy job at a time: yosys peaks over 10 GB on an 11 GB box.
for f in .pid_absiso .pid_seed_ab; do
    [ -f "$f" ] || continue
    P=$(cat "$f")
    echo "waiting for $f pid $P -- $(date -Is)"
    while kill -0 "$P" 2>/dev/null; do sleep 60; done
done
echo "clear to build -- $(date -Is)"

if [ ! -f "$OUT/am01_qmtech_top.fp.json" ]; then
    echo "=== synthesis: outreg schedule, extra_delay=2, absorption ON -- $(date -Is) ==="
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
        gen/encrypt_outreg_e2.v > "$OUT/build.log" 2>&1
    echo "    build.sh exit $? -- $(date -Is)"
fi

if [ ! -f "$OUT/am01_qmtech_top.fp.json" ]; then
    echo "NO NETLIST -- tail:"; tail -20 "$OUT/build.log"; exit 1
fi
echo "    DOA_REG=1 count: $(grep -ao '\"DOA_REG\": 1' "$OUT/am01_qmtech_top.fp.json" | wc -l) (expect 0)"

for s in $SEEDS; do
    d="seedrun/e2nb_s${s}"; mkdir -p "$d"
    echo "=== e2nb seed $s -- $(date -Is) ==="
    env NEXTPNR_ARC_MAX_VISIT=2000000 NEXTPNR_ROUTER2_MAX_STALL=250 \
        NEXTPNR_CRIT_DIST_EXP=1.0 \
        "$NEXTPNR" --chipdb "$CHIPDB" \
        --json "$OUT/am01_qmtech_top.fp.json" --xdc "$XDC" \
        --freq 133.33 --seed "$s" \
        --log "$d/route.log" >"$d/console" 2>&1
    f=$(grep -a "Max frequency for clock   'clk_h'" "$d/route.log" 2>/dev/null | tail -1 | sed -E "s/.*clk_h.: ([0-9.]+) MHz.*/\1/")
    i=$(grep -a "iter=" "$d/route.log" 2>/dev/null | tail -1 | sed -E "s/.*iter=([0-9]+).*/\1/")
    o=$(grep -a "iter=" "$d/route.log" 2>/dev/null | tail -1 | sed -E "s/.*overuse=([0-9]+).*/\1/")
    printf "%s	e2nb	%s\t%s\t%s\n" "$s" "${f:-FAIL}" "${i:--}" "${o:--}" >> "$RESULTS"
    tail -1 "$RESULTS"
    # Where does the path end now? state[0] again would refute the diagnosis.
    awk '/Critical path report for clock .clk_h. \(posedge/{i=1;next} i&&/Critical path report/{exit} i&&/Sink /{s=$0} END{gsub(/.*Sink /,"",s); print "      ends at: " s}' "$d/route.log"
done

echo
echo "=== ALL VARIANTS -- $(date -Is) ==="
for v in base outreg noabs e2; do
    vals=$(awk -v v="$v" -F'\t' '$2==v && $3!="FAIL" {print $3}' "$RESULTS" | sort -n)
    n=$(echo "$vals" | grep -c .)
    [ "$n" -eq 0 ] && continue
    med=$(echo "$vals" | awk -v n="$n" 'NR==int((n+1)/2)')
    printf "%-8s n=%-2s median %-8s  all: %s\n" "$v" "$n" "$med" "$(echo "$vals" | tr '\n' ' ')"
done
