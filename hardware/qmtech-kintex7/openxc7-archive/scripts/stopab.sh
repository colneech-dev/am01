#!/usr/bin/env bash
# Stop the A/B run started by run_outreg_ab.sh, by PID FILE, not by pattern.
#
# Why this exists: `pkill -f run_outreg_ab` (and `ps | grep | kill`) match the
# command line of the shell doing the killing, so they take down the caller as
# well as the target. That has happened repeatedly in this tree, including
# twice in one session -- once mid-build, losing 30 minutes of synthesis.
#
# Kills the whole process group so the yosys or nextpnr child dies with the
# driver; killing the driver alone leaves an 8 GB yosys orphaned.
set -uo pipefail
cd "$(dirname "$0")"

if [ ! -f .pid_ab ]; then
    echo "no .pid_ab -- nothing recorded as running"
    exit 0
fi

PID=$(cat .pid_ab)
if ! kill -0 "$PID" 2>/dev/null; then
    echo "pid $PID is not alive; clearing stale pid file"
    rm -f .pid_ab .pid_ab_child
    exit 0
fi

echo "stopping A/B driver pid $PID (process group)"
kill -TERM -- "-$PID" 2>/dev/null || kill -TERM "$PID" 2>/dev/null

for _ in $(seq 1 15); do
    kill -0 "$PID" 2>/dev/null || break
    sleep 1
done

if kill -0 "$PID" 2>/dev/null; then
    echo "still alive after 15s, sending KILL"
    kill -KILL -- "-$PID" 2>/dev/null || kill -KILL "$PID" 2>/dev/null
    sleep 2
fi

# The heavy child is the thing actually holding memory; make sure it went.
for c in yosys nextpnr-xilinx; do
    if pgrep -x "$c" >/dev/null 2>&1; then
        echo "WARNING: a $c is still running -- check it is not another experiment"
        pgrep -x "$c" | while read -r p; do
            ps -p "$p" -o pid,etime,rss,args --no-headers | cut -c1-120
        done
    fi
done

rm -f .pid_ab .pid_ab_child
echo "stopped"
