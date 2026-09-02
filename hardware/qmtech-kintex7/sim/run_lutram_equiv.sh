#!/usr/bin/env bash
# Functional equivalence run for the --lutram=N sbox conversion (Option A
# sizing: THROUGHPUT=2, 3 of 10 large S-boxes converted to distributed RAM).
# Same methodology as run_sched_equiv.sh (the known-good pattern for this
# project): queue-compare emitted results, mandatory negative control.
#
# Unlike the scheduling-change equivalence check, ref and tst here are
# IDENTICALLY scheduled (both THROUGHPUT=2, both --bram-out-reg, both
# latency 254) -- --lutram=N is a synthesis-attribute-only change, so a
# mismatch here would mean the conversion is not behaviour-neutral, which it
# should not be able to affect at the RTL level at all (ram_style does not
# change simulation semantics, only synthesis inference). Run anyway per
# this project's rule: nothing gets shipped on reasoning alone.
#
# RATE: iverilog runs these two 640-bit cores at roughly 8s/clock cycle
# (measured on tb_sched_equiv.v). THROUGHPUT=2 feeds and drains faster than
# THROUGHPUT=4 did, so fewer total cycles are needed for the same result
# count -- N=300 clears MIN_SEQ=8 with margin, at roughly 40 minutes.
set -uo pipefail
cd /tmp

TB=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/sim/tb_lutram_equiv.v
N="${N:-300}"

echo "== compiling -- $(date -Is) =="
iverilog -g2012 -o tb_lutram "$TB" v_ref.v v_tst.v || exit 1
echo "   ok"

echo
echo "== POSITIVE (must PASS) -- $(date -Is) =="
/usr/bin/time -f "   WALL %e s" ./tb_lutram +n="$N" +every=50 +drain=20 > lutram_pos.out 2>&1
echo "   sim exit $?"
tail -8 lutram_pos.out

echo
echo "== NEGATIVE CONTROL (must FAIL) -- $(date -Is) =="
/usr/bin/time -f "   WALL %e s" ./tb_lutram +n="$N" +every=50 +drain=20 +brk=3 > lutram_neg.out 2>&1
echo "   sim exit $?"
tail -8 lutram_neg.out

echo
echo "== VERDICT -- $(date -Is) =="
p=$(grep -a "RESULT:" lutram_pos.out | tail -1)
n=$(grep -a "RESULT:" lutram_neg.out | tail -1)
echo "   positive: ${p:-<none>}"
echo "   negative: ${n:-<none>}"
case "$p:$n" in
    *PASS*:*FAIL*) echo "   => SOUND: lutram conversion is behaviour-neutral, and the harness can detect divergence." ;;
    *PASS*:*PASS*) echo "   => WORTHLESS: negative control also passed. The comparison is not live." ;;
    *FAIL*:*)      echo "   => THE LUTRAM CONVERSION IS NOT BEHAVIOUR-NEUTRAL. Do not ship this configuration." ;;
    *)             echo "   => INCONCLUSIVE: see the .out files." ;;
esac
