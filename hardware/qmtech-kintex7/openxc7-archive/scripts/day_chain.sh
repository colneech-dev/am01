#!/usr/bin/env bash
# Run a slot's worth of experiments back to back, waiting on completion
# sentinels rather than the process table.
#
# Usage:  bash day_chain.sh <wait_tag|-> <spec> [<spec> ...]
#   spec = "tag|netlist.json|KNOB=VAL[,KNOB=VAL...]"
#
# Waiting rules learned the hard way in this project:
#   * NOT on a FASM -- only written on convergence, and non-convergence is half
#     of what we are measuring.
#   * NOT on pgrep/pkill -f -- those match the checking command's OWN command
#     line. One such pkill killed its parent shell here (exit 15) and silently
#     started nothing.
#   * NOT on log quiescence -- a live run goes silent for 10+ minutes between
#     the post-place report and the first router iteration. A 600 s quiescence
#     wait mistook that for completion and started a third concurrent nextpnr,
#     taking free memory to 2 GB with an OOM kill already on record.
# So: a sentinel file written by run_cfg.sh's EXIT trap.
set -euo pipefail

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7
OUT=out_nm1_nosr
MAX_WAIT=$((16*3600))

wait_for() {
    local tag="$1"
    local done_f="$OUT/.done_$tag"
    local log="$OUT/am01_qmtech_top_$tag.pnr.log"
    local deadline=$(( $(date +%s) + MAX_WAIT ))
    echo "-- waiting on $tag"
    while [ ! -e "$done_f" ]; do
        if [ "$(date +%s)" -gt "$deadline" ]; then
            echo "   max wait reached for $tag"
            break
        fi
        sleep 60
    done
    echo "-- $tag done:"
    grep -a 'iter=' "$log" 2>/dev/null | tail -1 || true
    grep -a "clock   'clk_h'" "$log" 2>/dev/null | tail -1 || true
}

WAIT_TAG="${1:?usage: day_chain.sh <wait_tag|-> <spec>...}"
shift
[ "$WAIT_TAG" != "-" ] && wait_for "$WAIT_TAG"

for spec in "$@"; do
    tag="${spec%%|*}"
    rest="${spec#*|}"
    json="${rest%%|*}"
    knobs="${rest#*|}"
    echo
    echo "################ $tag ################"
    # shellcheck disable=SC2086
    bash run_cfg.sh "$tag" "$json" ${knobs//,/ } || echo "   $tag failed"
done

echo
echo "=== slot complete ==="
echo "=== summary ==="
for spec in "$@"; do
    tag="${spec%%|*}"
    f="$OUT/am01_qmtech_top_$tag.pnr.log"
    fr=$(grep -a "clock   'clk_h'" "$f" 2>/dev/null | tail -1 | grep -oE '[0-9.]+ MHz' | head -1)
    it=$(grep -a 'iter=' "$f" 2>/dev/null | tail -1 | grep -oE 'iter=[0-9]+ .*overused=[0-9]+' | sed 's/wires=[0-9]* //')
    printf '  %-16s %-12s %s\n' "$tag" "${fr:-none}" "${it:-}"
done
