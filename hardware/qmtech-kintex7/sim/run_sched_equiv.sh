#!/usr/bin/env bash
# Functional equivalence run for the odo_gen scheduling change, with its
# mandatory negative control.
#
# WHY THIS MATTERS MORE THAN ANY TIMING NUMBER
# --------------------------------------------
# The configuration now recommended (--bram-out-reg, extra_delay>=1) changes
# real scheduling arithmetic: 2->3 cycles per round, extra_delay 1->2,
# round-key tap period[2*i]->period[3*i], period depth [42:0]->[64:0], latency
# 172->253. None of that has ever been functionally verified. An off-by-one
# there does not crash -- the miner runs and produces wrong hashes, which show
# up as silent pool rejects.
#
# RATE, MEASURED
# --------------
# iverilog runs these two 640-bit cores at roughly 8 SECONDS per clock cycle.
# That is why the original attempt never finished: it asked for 1000 cycles
# including a 420-cycle drain, i.e. hours, and printed nothing until the end so
# there was no way to tell slow from stuck.
#
# Sized accordingly: the test core's pipeline is 253 deep and a block is fed
# every 8 cycles, so results start emerging around cycle 253 and arrive one per
# 8 cycles thereafter. n=340 yields ~10 comparable results, which clears
# MIN_SEQ=8, at roughly 45-50 minutes per run.
#
# Both runs are required. A PASS with no accompanying FAIL from the negative
# control proves only that the harness is inert.
set -uo pipefail
cd /tmp

TB=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/sim/tb_sched_equiv.v
N="${N:-340}"

echo "== compiling -- $(date -Is) =="
iverilog -g2012 -o tb_sched "$TB" v_ref.v v_tst.v || exit 1
echo "   ok"

echo
echo "== POSITIVE (must PASS) -- $(date -Is) =="
/usr/bin/time -f "   WALL %e s" ./tb_sched +n="$N" +every=50 +drain=20 > sched_pos.out 2>&1
echo "   sim exit $?"
tail -8 sched_pos.out

echo
echo "== NEGATIVE CONTROL (must FAIL) -- $(date -Is) =="
/usr/bin/time -f "   WALL %e s" ./tb_sched +n="$N" +every=50 +drain=20 +brk=3 > sched_neg.out 2>&1
echo "   sim exit $?"
tail -8 sched_neg.out

echo
echo "== VERDICT -- $(date -Is) =="
p=$(grep -a "RESULT:" sched_pos.out | tail -1)
n=$(grep -a "RESULT:" sched_neg.out | tail -1)
echo "   positive: ${p:-<none>}"
echo "   negative: ${n:-<none>}"
case "$p:$n" in
    *PASS*:*FAIL*) echo "   => SOUND: cores agree, and the harness can detect divergence." ;;
    *PASS*:*PASS*) echo "   => WORTHLESS: negative control also passed. The comparison is not live." ;;
    *FAIL*:*)      echo "   => THE SCHEDULING CHANGE IS BROKEN. Do not ship this configuration." ;;
    *)             echo "   => INCONCLUSIVE: see the .out files." ;;
esac
