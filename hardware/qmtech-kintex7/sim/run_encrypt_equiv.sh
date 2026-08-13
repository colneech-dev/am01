#!/usr/bin/env bash
# Regenerate the shared-BRAM encrypt core and prove it equivalent to the
# stock one. Run this after every OdoCrypt epoch, since encrypt.v is
# regenerated (the cipher mutates every 10 days) and the transform in
# ../tools/mux2_transform.py has to be re-applied and re-proved.
#
#   ./run_encrypt_equiv.sh [workdir]
#
# Runs BOTH interleave polarities. +pinv=0 is the intended one and must
# PASS; +pinv=1 is a control and must FAIL -- if the control passes, the
# testbench is not sensitive to the interleave and the pass is worthless.
#
# Budget ~30 min per polarity (they run concurrently): the OdoCrypt core
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

echo "==> [4/4] simulating both polarities (this takes ~30 min)"
"$WORK/sim_equiv" +pinv=0 > "$WORK/equiv0.log" 2>&1 &
p0=$!
"$WORK/sim_equiv" +pinv=1 > "$WORK/equiv1.log" 2>&1 &
p1=$!
wait $p0; wait $p1

echo
echo "--- intended polarity (must PASS) ---"
cat "$WORK/equiv0.log"
echo "--- control polarity (must FAIL) ---"
cat "$WORK/equiv1.log"

ok0=$(grep -c "RESULT: PASS" "$WORK/equiv0.log")
bad1=$(grep -cE "RESULT: (FAIL|INCONCLUSIVE)" "$WORK/equiv1.log")
echo
if [ "$ok0" -eq 1 ] && [ "$bad1" -eq 1 ]; then
    echo "OVERALL: PASS -- equivalent, and the test is sensitive to the interleave"
    exit 0
fi
echo "OVERALL: NOT PROVEN (intended_pass=$ok0 control_failed=$bad1)"
exit 1
