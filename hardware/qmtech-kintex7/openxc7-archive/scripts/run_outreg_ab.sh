#!/usr/bin/env bash
# A/B the BRAM output register: same RTL, same epoch, same seed, one variable.
#
# WHY A FRESH BASELINE RATHER THAN COMPARING AGAINST 129.79
# ---------------------------------------------------------
# The 129.79 MHz result cannot be the control for this experiment. Two things
# have changed under it since:
#   * the epoch rolled to 1787616000, so encrypt.v is a different cipher
#   * odocrypt_gpio_wrapper.v gained the XADC/fan/LCD work (cf772fb, today)
# Comparing the new outreg build against it would attribute all three to the
# BRAM register. So both sides are rebuilt here from identical current RTL and
# the only difference is `odo_gen --bram-out-reg`.
#
# NO_XADC is passed to BOTH sides. The open-source flow cannot place an XADC on
# this part at all -- prjxray's kintex7 database has zero XADC tiles -- so
# without it neither side reaches place-and-route. See the guard in
# odocrypt_gpio_wrapper.v.
#
# Runs strictly sequentially. Two concurrent yosys runs on this design have
# pushed WSL into memory exhaustion before.
set -euo pipefail

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7
REPO=/mnt/c/Users/Colin/Documents/GitHub/am01
EPOCH=$(cat "$REPO/hdl/odocrypt/EPOCH")

# Record the driver pid and whatever tool is currently running under it, so this
# can be stopped by FILE rather than by pattern.
#
# `pkill -f run_outreg_ab` matches the command line of the shell doing the
# killing and takes down the caller -- that has happened repeatedly here,
# including twice in this session. Stop with:  bash stopab.sh
echo $$ > .pid_ab
trap 'rm -f .pid_ab .pid_ab_child' EXIT
child () { echo "$1" > .pid_ab_child; }

SRCS=(
    "$REPO/hardware/qmtech-kintex7/hdl/am01_qmtech_top_nm1.v"
    "$REPO/hardware/qmtech-kintex7/hdl/clk_gen_hash.v"
    "$REPO/hardware/qmtech-kintex7/hdl/odocrypt_gpio_wrapper.v"
    "$REPO/hdl/odocrypt/atomminer_misc.v"
    "$REPO/hdl/odocrypt/keccak800.v"
    "$REPO/hdl/odocrypt/miner.v"
)

echo "=== epoch $EPOCH ==="
( cd "$REPO/tools/odo_gen" && make -s odo_gen )

gen () {   # gen <outfile> [--bram-out-reg]
    local out="$1"; shift
    "$REPO/tools/odo_gen/odo_gen" "$EPOCH" 4 encrypt_4 "$@" > "$out"
    printf "  %-28s %8d lines  a_q1=%d\n" "$(basename "$out")" \
        "$(wc -l < "$out")" "$(grep -c a_q1 "$out" || true)"
}

mkdir -p gen
gen gen/encrypt_base.v
gen gen/encrypt_outreg.v --bram-out-reg

run () {   # run <tag> <encrypt.v> <BRAM_OUTREG>
    local tag="$1" enc="$2" outreg="$3"
    local out="out_ab_$tag"
    echo
    echo "=== [$tag] synthesis -- $(date -Is) ==="
    mkdir -p "$out"
    # FREQ has no default in build.sh by design: nextpnr times every clock
    # domain against it here, so a wrong value signs off at the wrong speed.
    # build.sh defaults XDC to <dir of first source>/<top>.xdc, which does not
    # exist here -- the constraints live under xdc/ with a board-specific name.
    SRL=0 FREQ=133.33 DEFINES=NO_XADC BRAM_OUTREG="$outreg" BRAM_FP=1 BRAM_YBASE=40 \
        XDC="$REPO/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc" \
        bash build.sh am01_qmtech_top "$out" "${SRCS[@]}" "$enc" \
        > "$out/build.log" 2>&1 || {
            echo "  [$tag] BUILD FAILED -- tail:"; tail -25 "$out/build.log"; return 1; }
    echo "  [$tag] done -- $(date -Is)"
    grep -aE "Max frequency for clock" "$out/am01_qmtech_top.pnr.log" | tail -2 || true
}

run base   gen/encrypt_base.v   0 || true
run outreg gen/encrypt_outreg.v 1 || true

echo
echo "=== A/B SUMMARY -- $(date -Is) ==="
for t in base outreg; do
    printf "%-8s " "$t"
    grep -aE "Max frequency for clock" "out_ab_$t/am01_qmtech_top.pnr.log" 2>/dev/null \
        | tail -1 || echo "(no result)"
done
