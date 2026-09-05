#!/usr/bin/env bash
# Sequence budget experiments in one slot. Replaces chain_budget.sh.
#
# WHY chain_budget.sh WAS WRONG
# -----------------------------
# It treated "log untouched for 600 s" as completion. That is not a completion
# signal: a live run goes silent for well over ten minutes between the
# post-place report and the first router iteration, while "Setting up routing
# resources" runs. Slot A mistook that gap for a finished run and started a
# third concurrent nextpnr, taking free memory from 9 GB to 2 GB -- with an
# OOM-kill (exit 137) already on record in this project.
#
# WHY NOT THE OBVIOUS ALTERNATIVES
# --------------------------------
# * Waiting on the FASM assumes the run CONVERGES. WIRE_DEMAND=1.0 ran 174
#   iterations without producing one, and whether a configuration converges is
#   precisely what these runs are measuring.
# * pgrep/pkill -f match the checking command's OWN command line. That killed a
#   parent shell here earlier today (exit 15) and silently started nothing.
#
# So this waits for a completion SENTINEL that the launcher writes after the
# nextpnr process exits, whatever its exit status. Unambiguous, artefact-based,
# and it needs no process table.
#
# Usage:
#   bash chain2_budget.sh <wait_tag> [<tag> <budget> <KNOB=VAL>]...
#     wait_tag  = "-" to start immediately, else a tag whose sentinel to await
set -euo pipefail

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

OUT=out_nm1_nosr
MAX_WAIT=$((14*3600))
POLL=60

sentinel_of() { echo "$OUT/.done_$1"; }
log_of()      { echo "$OUT/am01_qmtech_top_$1.pnr.log"; }

report() {
    local tag="$1" log; log="$(log_of "$tag")"
    echo "-- $tag finished"
    grep -a 'iter=' "$log" 2>/dev/null | tail -1 || true
    grep -a 'Max frequency' "$log" 2>/dev/null | tail -2 || true
}

# Wait for a tag that is ALREADY RUNNING and was started without a sentinel.
# Fall back to a long quiescence window -- 40 minutes, comfortably longer than
# the silent routing-setup gap that broke the previous version.
wait_legacy() {
    local tag="$1" log; log="$(log_of "$tag")"
    local quiet=2400
    local deadline=$(( $(date +%s) + MAX_WAIT ))
    echo "-- waiting for already-running $tag (quiescence ${quiet}s)"
    while [ ! -e "$log" ]; do
        [ "$(date +%s)" -gt "$deadline" ] && return 0
        sleep 30
    done
    while :; do
        local age=$(( $(date +%s) - $(date -r "$log" +%s) ))
        [ "$age" -ge "$quiet" ] && break
        [ "$(date +%s)" -gt "$deadline" ] && { echo "   max wait reached"; break; }
        sleep "$POLL"
    done
    report "$tag"
}

# Launch a run and write its sentinel when the process exits, whatever happens.
launch() {
    local tag="$1" budget="$2" knob="$3"
    local done_f; done_f="$(sentinel_of "$tag")"
    rm -f "$done_f"
    echo
    echo "=== starting $tag (ARC_MAX_VISIT=$budget, $knob) ==="
    bash run_budget.sh "$tag" "$budget" "$knob" || echo "   $tag exited non-zero"
    touch "$done_f"
    report "$tag"
}

WAIT_TAG="${1:?usage: chain2_budget.sh <wait_tag|-> [<tag> <budget> <KNOB=VAL>]...}"
shift
[ "$WAIT_TAG" != "-" ] && wait_legacy "$WAIT_TAG"

while [ "$#" -ge 3 ]; do
    launch "$1" "$2" "$3"
    shift 3
done

echo
echo "=== slot complete ==="
