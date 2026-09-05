#!/usr/bin/env bash
# Generic experiment runner: one tag, one netlist, arbitrary env knobs.
#
# Usage:  bash run_cfg.sh <tag> <netlist.json> [KNOB=VAL ...]
#
# Always sets ARC_MAX_VISIT=2000000 and MAX_STALL=250, because those are the
# router settings under which the current best result was obtained:
#   200k errors out on this design's BRAM-egress arcs
#   unbounded oscillates and never converges
#   max_stall=50 kills descending runs (it counts iterations since the BEST
#   overuse improved, not since the last improvement)
#
# Writes a completion sentinel on EXIT whatever the outcome, so a chain can wait
# on it. Do NOT wait on the FASM -- that only exists if a run converges, and
# whether a configuration converges is half of what these runs measure.
set -euo pipefail

TAG="${1:?usage: run_cfg.sh <tag> <netlist.json> [KNOB=VAL ...]}"
JSON="${2:?netlist}"
shift 2

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
OUT=out_nm1_nosr

for f in "$NEXTPNR" "$CHIPDB" "$XDC" "$JSON"; do
    [ -e "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

DONE="$OUT/.done_$TAG"
PIDF="$OUT/.pid_$TAG"
rm -f "$DONE"
# Record the nextpnr pid so it can be stopped by FILE rather than by pattern.
# `ps aux | grep PATTERN | kill` and `pkill -f PATTERN` both match the checking
# command's own command line and have repeatedly killed the wrong thing here --
# including parent shells and experiment chains meant to survive. See stoprun.sh.
trap 'touch "$DONE"; rm -f "$PIDF"' EXIT

# SEED is a nextpnr command-line option, not an env knob, so it cannot be passed
# through "$@" with the others. It matters: measured seed spread on this design
# is ~22 MHz, so a comparison run must pin the same seed as the result it is
# being compared against, or the difference measured is mostly noise.
SEED_ARG=()
[ -n "${SEED:-}" ] && SEED_ARG=(--seed "$SEED")

echo "== $TAG =="
echo "   netlist: $JSON"
echo "   knobs  : $*  ${SEED:+seed=$SEED}"
env NEXTPNR_ARC_MAX_VISIT=2000000 NEXTPNR_ROUTER2_MAX_STALL=250 "$@" "$NEXTPNR" \
    --chipdb "$CHIPDB" \
    --json "$JSON" \
    --xdc "$XDC" \
    --freq 133.33 \
    ${SEED_ARG[@]+"${SEED_ARG[@]}"} \
    --write "$OUT/placed_$TAG.json" \
    --fasm "$OUT/am01_qmtech_top_$TAG.fasm" \
    --log "$OUT/am01_qmtech_top_$TAG.pnr.log" &
NPPID=$!
echo "$NPPID" > "$PIDF"
echo "   pid $NPPID (stop with: bash stoprun.sh $TAG)"
wait "$NPPID" || echo "   $TAG exited non-zero"

echo "== $TAG result (best so far: vfp_cde 93.28 MHz; baseline 89.30) =="
grep -a "Max frequency for clock" "$OUT/am01_qmtech_top_$TAG.pnr.log" 2>/dev/null | tail -2 || true
grep -a 'iter=' "$OUT/am01_qmtech_top_$TAG.pnr.log" 2>/dev/null | tail -1 || true
