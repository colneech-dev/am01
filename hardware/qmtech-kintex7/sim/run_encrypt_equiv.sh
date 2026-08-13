#!/usr/bin/env bash
# Regenerate the shared-BRAM encrypt core and prove it equivalent to the
# stock one. Run this after every OdoCrypt epoch, since encrypt.v is
# regenerated (the cipher mutates every 10 days) and the transform in
# ../tools/mux2_transform.py has to be re-applied and re-proved.
#
#   ./run_encrypt_equiv.sh [workdir]
#
# Runs three configurations concurrently:
#
#   +pinv=0             intended interleave        -- must PASS
#   +pstuck=1           phase held constant        -- must FAIL
#   +pinv=1             phase inverted             -- expected to pass
#
# The middle one is the negative control: holding phase constant means
# slot 1 is never serviced, i.e. genuinely broken hardware. If that run
# passes, the testbench cannot detect a broken interleave and the first
# run's PASS is worthless.
#
# +pinv=1 is NOT a control -- inverting the phase is a benign relabelling
# (both slots are still serviced once per clk_h; only the sub-clk_h moment
# each output register updates changes, and both settle before the next
# clk_h sampling edge). It is run to confirm the design tolerates either
# alignment, which is useful to know but proves nothing about sensitivity.
#
# Budget ~35-45 min (they run concurrently and contend): the OdoCrypt core
# simulates at roughly 2.7 s per clock cycle here, and the pipeline is
# 172 stages deep before any output is even defined.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ODO="$HERE/../../../exmaples/odocrypt/fpga/src/hdl"
WORK="${1:-${TMPDIR:-/tmp}/encrypt-equiv}"
mkdir -p "$WORK" || exit 1

echo "==> [1/4] generating shared-BRAM core"
python3 "$HERE/../tools/mux2_transform.py" "$ODO/encrypt.v" "$WORK/encrypt_mux2.v" || exit 1

# Namespace it so both cores can be elaborated in one simulation. All
# encrypt_4* identifiers in the generated file are module names -- no
# signal or port shares the prefix -- so a blanket rename is safe.
echo "==> [2/4] namespacing muxed core as mx_*"
sed -E 's/\bencrypt_4([A-Za-z0-9_]*)/mx_encrypt_4\1/g' \
    "$WORK/encrypt_mux2.v" > "$WORK/encrypt_mux2_renamed.v"
n_mod=$(grep -c '^module mx_encrypt_4' "$WORK/encrypt_mux2_renamed.v")
n_left=$(grep -c '[^_]encrypt_4' "$WORK/encrypt_mux2_renamed.v")
echo "    renamed $n_mod modules, $n_left unrenamed references left"
[ "$n_left" -eq 0 ] || { echo "ERROR: rename was incomplete"; exit 1; }

echo "==> [3/4] compiling"
iverilog -g2005 -o "$WORK/sim_equiv" \
    "$HERE/tb_encrypt_equiv.v" \
    "$WORK/encrypt_mux2_renamed.v" \
    "$ODO/encrypt.v" || exit 1

echo "==> [4/4] simulating (this takes ~35-45 min)"
"$WORK/sim_equiv" +pinv=0   > "$WORK/equiv_intended.log" 2>&1 &
p0=$!
"$WORK/sim_equiv" +pstuck=1 > "$WORK/equiv_stuck.log"    2>&1 &
p1=$!
"$WORK/sim_equiv" +pinv=1   > "$WORK/equiv_inverted.log" 2>&1 &
p2=$!
wait $p0; wait $p1; wait $p2

echo
echo "--- intended interleave (must PASS) ---"
cat "$WORK/equiv_intended.log"
echo "--- NEGATIVE CONTROL, phase held constant (must FAIL) ---"
cat "$WORK/equiv_stuck.log"
echo "--- phase inverted (expected to pass; not a control) ---"
cat "$WORK/equiv_inverted.log"

ok=$(grep -c "RESULT: PASS" "$WORK/equiv_intended.log")
ctl=$(grep -c "RESULT: FAIL" "$WORK/equiv_stuck.log")
echo
if [ "$ok" -eq 1 ] && [ "$ctl" -eq 1 ]; then
    echo "OVERALL: PASS -- equivalent, and the test provably detects a broken interleave"
    exit 0
fi
if [ "$ok" -eq 1 ] && [ "$ctl" -ne 1 ]; then
    echo "OVERALL: NOT PROVEN -- the intended run passed, but so did the negative"
    echo "         control. The test cannot detect broken hardware, so its PASS"
    echo "         carries no weight. Fix the testbench before believing it."
    exit 1
fi
echo "OVERALL: NOT PROVEN (intended_passed=$ok control_failed=$ctl)"
exit 1
