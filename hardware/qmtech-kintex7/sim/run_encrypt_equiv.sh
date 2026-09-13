#!/usr/bin/env bash
# Regenerate the shared-BRAM encrypt core and prove it equivalent to the
# stock one. Run this after every OdoCrypt epoch, since encrypt.v is
# regenerated (the cipher mutates every 10 days) and the transform in
# ../tools/mux2_transform.py has to be re-applied and re-proved.
#
#   ./run_encrypt_equiv.sh [workdir]
#
# Runs three configurations concurrently. Each needs its OWN binary: the
# phase is generated inside each muxed box now, so the configuration is a
# -D at compile time and not a plusarg at run time.
#
#   (no define)             local phase, as shipped     -- must PASS
#   -DMUX_PHASE_STUCK       local phase held at 0       -- must FAIL
#   -DMUX_PHASE_FROM_PORT   broadcast phase, +pinv=1    -- expected to pass
#
# The middle one is the negative control: a phase that never toggles means
# slot 1 is never serviced, i.e. genuinely broken hardware. If that run
# passes, the testbench cannot detect a broken interleave and the first
# run's PASS is worthless.
#
# The third is NOT a control. It does two useful things, neither of which is
# a sensitivity check: it proves MUX_PHASE_FROM_PORT still builds a working
# core, so reverting to the broadcast phase is one -D away; and it confirms
# that inverting that phase is a benign relabelling (both slots are still
# serviced once per clk_h; only the sub-clk_h moment each output register
# updates changes, and both settle before the next clk_h sampling edge).
#
# That last point is also why the LOCAL phase is safe. Each box owns its own
# `mem`, and nothing outside a box reads phase, so a box out of step with
# its neighbours is exactly this benign case -- measured, not assumed.
# Lockstep between boxes is guaranteed anyway (INIT=0, no enable, no reset),
# but it is not load-bearing.
#
# Budget ~35-45 min (they run concurrently and contend): the OdoCrypt core
# simulates at roughly 2.7 s per clock cycle here, and the pipeline is
# 172 stages deep before any output is even defined.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ODO="$HERE/../../../hdl/odocrypt"
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

echo "==> [3/4] compiling three configurations"
for cfg in "local:" "stuck:-DMUX_PHASE_STUCK" "port:-DMUX_PHASE_FROM_PORT"; do
    name="${cfg%%:*}"
    def="${cfg#*:}"
    # shellcheck disable=SC2086
    iverilog -g2005 $def -o "$WORK/sim_$name" \
        "$HERE/tb_encrypt_equiv.v" \
        "$WORK/encrypt_mux2_renamed.v" \
        "$ODO/encrypt.v" || exit 1
    echo "    built sim_$name ${def:-(no define)}"
done

echo "==> [4/4] simulating (this takes ~35-45 min)"
"$WORK/sim_local"          > "$WORK/equiv_intended.log" 2>&1 &
p0=$!
"$WORK/sim_stuck"          > "$WORK/equiv_stuck.log"    2>&1 &
p1=$!
"$WORK/sim_port"  +pinv=1  > "$WORK/equiv_inverted.log" 2>&1 &
p2=$!
wait $p0; wait $p1; wait $p2

echo
echo "--- local phase, as shipped (must PASS) ---"
cat "$WORK/equiv_intended.log"
echo "--- NEGATIVE CONTROL, local phase held at 0 (must FAIL) ---"
cat "$WORK/equiv_stuck.log"
echo "--- broadcast phase, inverted (expected to pass; not a control) ---"
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
