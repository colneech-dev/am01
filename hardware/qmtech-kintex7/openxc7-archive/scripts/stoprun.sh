#!/usr/bin/env bash
# Stop a run by PID FILE. Never by pattern.
#
# WHY THIS EXISTS
# ---------------
# `ps aux | grep PATTERN | awk '{print $2}' | xargs kill` and `pkill -f PATTERN`
# both match the CHECKING COMMAND'S OWN command line, because the pattern is
# necessarily present in it. In this project that has:
#
#   * killed the parent shell with exit 15, silently starting nothing
#     (pkill -f queue_small_beta.sh)
#   * reported phantom running processes and hung waits forever
#     (pgrep -f "cmake --build", six recorded occurrences)
#   * killed two experiment chains that were meant to survive
#
# It has now happened at least three times AFTER being documented as a hazard,
# which is the evidence that "remember to be careful" is not a control. Pattern
# matching against the process table is the defect; removing it is the fix.
#
# run_cfg.sh writes out_nm1_nosr/.pid_<tag>. This reads that file and kills
# exactly that pid. No pattern, no self-match possible.
#
# Usage:  bash stoprun.sh <tag> [<tag> ...]
#         bash stoprun.sh --list
set -euo pipefail

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7
OUT=out_nm1_nosr

if [ "${1:-}" = "--list" ]; then
    echo "tracked runs:"
    for f in "$OUT"/.pid_*; do
        [ -e "$f" ] || { echo "  (none)"; break; }
        tag="$(basename "$f")"; tag="${tag#.pid_}"
        pid="$(cat "$f" 2>/dev/null || echo '?')"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            state=RUNNING
        else
            state=finished
        fi
        printf '  %-16s pid %-8s %s\n' "$tag" "$pid" "$state"
    done
    exit 0
fi

[ "$#" -ge 1 ] || { echo "usage: stoprun.sh <tag>... | --list"; exit 1; }

for tag in "$@"; do
    f="$OUT/.pid_$tag"
    if [ ! -e "$f" ]; then
        echo "  $tag: no pid file"
        continue
    fi
    pid="$(cat "$f")"
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" && echo "  $tag: stopped pid $pid"
    else
        echo "  $tag: pid $pid already gone"
    fi
done
