#!/usr/bin/env bash
# Wait for the HPWL_SCALE_FIX route to finish, then full-route WIRE_DEMAND=1.0.
#
# WHY WIRE_DEMAND=1.0
# -------------------
# Placement-only screen, against baseline 13045 / 4260448:
#
#   WIRE_DEMAND=2.0   timing cost 12894   wirelen 4222197
#   WIRE_DEMAND=1.0   timing cost 10836   wirelen 4180296   <- optimum
#   WIRE_DEMAND=0.5   timing cost 13977   wirelen 4224149
#
# A real optimum, not a trend: too loose and no tile trips, too tight and the
# spreader thins the whole die. 1.0 is also the first configuration this session
# to beat baseline on BOTH metrics, and the only candidate that is
# congestion-aware by construction -- build_wire_demand() recomputes a RUDY map
# from current cell positions every spreader run, so the placement adapts to
# routing demand instead of only to BEL overflow (which at 9% LUT utilisation
# never happens).
#
# WAITING ON AN ARTEFACT, NOT THE PROCESS TABLE
# ---------------------------------------------
# Earlier waits in this project used `pgrep -f <pattern>`, which matches the
# checking command's OWN command line -- it reports a phantom running process
# and never returns. Six occurrences of that bug are on record here, including a
# chained rebuild that waited on itself forever. Wait for the FASM the previous
# run emits instead; it exists only once that run has actually completed.
set -euo pipefail

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
JSON=out_nm1_nosr/am01_qmtech_top_v68.json
OUT=out_nm1_nosr

WAIT_FOR="$OUT/am01_qmtech_top_hpwlfix.fasm"
PREV_LOG="$OUT/am01_qmtech_top_hpwlfix.pnr.log"

echo "== waiting for $WAIT_FOR =="
# Cap the wait so a stalled predecessor cannot hang this forever. The baseline
# converged at router iteration 45; a run still going after 6 hours is stuck.
deadline=$(( $(date +%s) + 6*3600 ))
while [ ! -e "$WAIT_FOR" ]; do
    if [ "$(date +%s)" -gt "$deadline" ]; then
        echo "TIMEOUT: $WAIT_FOR never appeared; predecessor likely stalled."
        echo "last predecessor iteration:"
        grep -a 'iter=' "$PREV_LOG" 2>/dev/null | tail -1
        echo "proceeding anyway -- the two runs do not share state."
        break
    fi
    sleep 60
done

echo "== predecessor result (HPWL_SCALE_FIX) =="
grep -a "Max frequency for clock" "$PREV_LOG" 2>/dev/null | tail -2 || echo "  (none)"
grep -a 'iter=' "$PREV_LOG" 2>/dev/null | tail -1 || true

echo
echo "== NEXTPNR_WIRE_DEMAND=1.0, full place and route =="
NEXTPNR_WIRE_DEMAND=1.0 "$NEXTPNR" \
    --chipdb "$CHIPDB" \
    --json "$JSON" \
    --xdc "$XDC" \
    --freq 133.33 \
    --write "$OUT/placed_wd10.json" \
    --fasm "$OUT/am01_qmtech_top_wd10.fasm" \
    --log "$OUT/am01_qmtech_top_wd10.pnr.log"

echo "== routed result (compare against baseline 89.30 MHz) =="
grep -a "Max frequency for clock" "$OUT/am01_qmtech_top_wd10.pnr.log" | tail -2
grep -a 'iter=' "$OUT/am01_qmtech_top_wd10.pnr.log" | tail -1
