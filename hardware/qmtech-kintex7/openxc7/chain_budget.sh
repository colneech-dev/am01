#!/usr/bin/env bash
# Run a sequence of budget experiments in one slot, waiting on QUIESCENCE.
#
# WHY NOT WAIT ON A FASM, AND WHY NOT ON pgrep
# --------------------------------------------
# * A FASM is only written when a run CONVERGES. WIRE_DEMAND=1.0 ran to
#   iteration 174 without converging, so a FASM-based wait would have idled
#   until its timeout. Half the point of these runs is to observe whether a
#   configuration converges at all, so the wait must not assume it does.
# * `pgrep -f <pattern>` / `pkill -f <pattern>` match the checking command's OWN
#   command line. That has bitten this project repeatedly -- most recently a
#   `pkill -f queue_small_beta.sh` that killed its own parent shell (exit 15)
#   and silently started nothing.
#
# So: wait until the run's .pnr.log has stopped growing for QUIET seconds. That
# is an artefact, it needs no process table, and it terminates whether the run
# converged, stalled, or died.
#
# Usage:  bash chain_budget.sh <wait_for_tag> <tag> <budget> <KNOB=VAL> [<tag> <budget> <KNOB=VAL> ...]
set -euo pipefail

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

OUT=out_nm1_nosr
QUIET=600          # log untouched this long => run is over
MAX_WAIT=$((14*3600))

wait_quiet() {
    local log="$OUT/am01_qmtech_top_$1.pnr.log"
    local deadline=$(( $(date +%s) + MAX_WAIT ))
    echo "-- waiting for $1 to quiesce ($QUIET s of no log growth)"
    # Give the log a chance to appear at all.
    while [ ! -e "$log" ]; do
        [ "$(date +%s)" -gt "$deadline" ] && { echo "   timeout waiting for $log"; return 0; }
        sleep 30
    done
    while :; do
        local age=$(( $(date +%s) - $(date -r "$log" +%s) ))
        [ "$age" -ge "$QUIET" ] && break
        [ "$(date +%s)" -gt "$deadline" ] && { echo "   max wait reached"; break; }
        sleep 60
    done
    echo "-- $1 finished. last iteration:"
    grep -a 'iter=' "$log" 2>/dev/null | tail -1 || true
    grep -a 'Max frequency' "$log" 2>/dev/null | tail -2 || true
}

WAIT_FOR="${1:?usage: chain_budget.sh <wait_for_tag> <tag> <budget> <KNOB=VAL> ...}"
shift
wait_quiet "$WAIT_FOR"

while [ "$#" -ge 3 ]; do
    tag="$1"; budget="$2"; knob="$3"; shift 3
    echo
    echo "=== starting $tag (ARC_MAX_VISIT=$budget, $knob) ==="
    bash run_budget.sh "$tag" "$budget" "$knob" || echo "   $tag exited non-zero"
    wait_quiet "$tag"
done

echo
echo "=== slot complete ==="
