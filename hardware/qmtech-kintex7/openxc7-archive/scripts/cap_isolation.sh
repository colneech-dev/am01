#!/usr/bin/env bash
# Stop the absorption-isolation sweep after 2 seeds so the e2 candidate can run.
#
# WHY CAP IT
# ----------
# run_absorb_isolation.sh routes 5 seeds of "outreg RTL, absorption OFF", which
# is the extra_delay=0 schedule -- the one now proven broken (critical path ends
# at state[0] on every seed, 31 MHz below base). Its question is "is absorption
# itself positive?", and 2 seeds answer that well enough: if noabs lands in
# 81-85 like the absorbed build did, the schedule owns the whole loss and
# absorption is neutral.
#
# Meanwhile run_e2.sh -- the candidate that actually matters, output register
# PLUS the recirculation relay -- is blocked behind it, and the full queue is
# ~10 hours. Capping at 2 seeds starts e2 about 3 hours earlier.
#
# Waits for the 2nd noabs row rather than killing blind, so the in-flight route
# is never truncated mid-run and its result is always recorded.
set -uo pipefail
cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

WANT="${WANT:-2}"
RESULTS=seed_ab_results.tsv

echo "capping isolation at $WANT seeds -- $(date -Is)"
while :; do
    n=$(awk -F'\t' '$2=="noabs"{c++} END{print c+0}' "$RESULTS" 2>/dev/null)
    [ "${n:-0}" -ge "$WANT" ] && break
    [ -f .pid_absiso ] || { echo "isolation already finished on its own"; exit 0; }
    sleep 60
done

echo "$WANT noabs rows present -- $(date -Is)"
awk -F'\t' '$2=="noabs"' "$RESULTS"

if [ -f .pid_absiso ]; then
    P=$(cat .pid_absiso)
    echo "stopping isolation driver pid $P (process group)"
    # Group kill: killing the driver alone orphans the nextpnr it spawned.
    kill -TERM -- "-$P" 2>/dev/null || kill -TERM "$P" 2>/dev/null
    for _ in $(seq 1 20); do kill -0 "$P" 2>/dev/null || break; sleep 1; done
    kill -0 "$P" 2>/dev/null && { kill -KILL -- "-$P" 2>/dev/null || kill -KILL "$P" 2>/dev/null; }
    rm -f .pid_absiso
    echo "isolation stopped; run_e2.sh will pick up within a minute"
fi
