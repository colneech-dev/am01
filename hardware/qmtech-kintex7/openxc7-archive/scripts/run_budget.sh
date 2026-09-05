#!/usr/bin/env bash
# Full place-and-route with an EXPLICIT router arc-visit budget.
#
# WHY THIS EXISTS
# ---------------
# Every experiment in the 2026-08-24 session ran with NEXTPNR_ARC_MAX_VISIT
# unset, i.e. the code default of 0 = UNBOUNDED (common/router2.cc:1142-1144).
# That is not a neutral choice:
#
#   * TESTS-TO-RUN.md:135 already records the failure mode -- "does NOT stall
#     the way the 2M-budget run did (~120 overused, oscillating)".
#   * WIRE_DEMAND=1.0 was killed at iteration 174 oscillating 16-33 with
#     wirelength climbing monotonically. Same signature.
#   * The router code review flagged unbounded ARC_MAX_VISIT as a defect: a
#     genuinely unroutable arc drains the whole ~1.4M-wire device graph before
#     failing, so a single iteration can take hours.
#   * seed_sweep.sh -- the one script here with recorded working runs -- sets
#     200000.
#
# So candidates were failed on oscillating convergence that may have been the
# ROUTER'S BUDGET rather than the placement. Those refutations are not safe
# until re-run at a bounded budget. The 89.30 MHz baseline's own budget is
# unknown (it predates the session), which is a second confound.
#
# Usage:  bash run_budget.sh <tag> <arc_max_visit> [KNOB=VAL ...]
#   e.g.  bash run_budget.sh wd10_200k 200000 NEXTPNR_WIRE_DEMAND=1.0
#         bash run_budget.sh cde10_2m 2000000 NEXTPNR_CRIT_DIST_EXP=1.0
#
# WHAT TO WATCH
# -------------
# Convergence FIRST, against the baseline at the SAME iteration: 395 at iter 9,
# 60 at 17, 14 at 25, 1 at 41, 0 at 45. Only then the ROUTED "Max frequency"
# line against 89.30 MHz. The post-place estimate is anti-correlated with the
# routed result on every candidate measured so far -- ignore it.
set -euo pipefail

TAG="${1:?usage: run_budget.sh <tag> <arc_max_visit> [KNOB=VAL ...]}"
BUDGET="${2:?usage: run_budget.sh <tag> <arc_max_visit> [KNOB=VAL ...]}"
shift 2

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
JSON=out_nm1_nosr/am01_qmtech_top_v68.json
OUT=out_nm1_nosr

for f in "$NEXTPNR" "$CHIPDB" "$XDC" "$JSON"; do
    [ -e "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

echo "== $TAG : ARC_MAX_VISIT=$BUDGET $* =="
env NEXTPNR_ARC_MAX_VISIT="$BUDGET" "$@" "$NEXTPNR" \
    --chipdb "$CHIPDB" \
    --json "$JSON" \
    --xdc "$XDC" \
    --freq 133.33 \
    --write "$OUT/placed_$TAG.json" \
    --fasm "$OUT/am01_qmtech_top_$TAG.fasm" \
    --log "$OUT/am01_qmtech_top_$TAG.pnr.log"

echo "== $TAG routed result (baseline 89.30 MHz) =="
grep -a "Max frequency for clock" "$OUT/am01_qmtech_top_$TAG.pnr.log" | tail -2
grep -a 'iter=' "$OUT/am01_qmtech_top_$TAG.pnr.log" | tail -1
