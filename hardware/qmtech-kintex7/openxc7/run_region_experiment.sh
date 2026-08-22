#!/usr/bin/env bash
# Per-round region constraints vs the striped baseline, as a controlled pair.
#
# WHY A CONTROL RUN
# -----------------
# The archived striped run reports 102.15 MHz, but NEXTPNR_ISO_HEURISTIC is
# env-gated and (until today) logged nothing, so no archived log records whether
# it was set. Comparing a new run against 102.15 without reproducing it first
# would repeat the mistake that produced the "Y-band is +12%" claim -- that
# number was measured against a baseline whose provenance had not been checked,
# and Y-band is in fact a ~10% regression.
#
# So: run the SAME striped input twice under a known, logged environment,
# changing exactly one thing.
#
#   A  striped, no regions    -> must land near 102.15 for B to mean anything
#   B  striped + regions      -> the experiment
#
# Both also pass --write, which the original striped run did not. Its placement
# was never saved (placed.json at 17:26 predates am01_qmtech_top_st.json at
# 17:29 -- it is the harvest placement, not the result), so the 102.15 placement
# could not be handed to Vivado's router. A saves it this time.
#
# WHAT B CHANGES
# --------------
# preplace_round_regions.py confines each round's recovered cells to a box around
# that round's own BRAMs. It reaches 51621 cells where floorplan_stripe.py reaches
# 420 -- 0.6% of the design. The measured critical path is a BRAM->LUT net at
# 6.9 ns against Vivado's 3.146 ns on the identical arc, and the offending LUT
# sits at tile (113,251) while its BRAM is at (19,5).
#
# SUCCESS CRITERION
# -----------------
# Not "Fmax went up" alone -- that invites reading noise as signal. The specific
# claim is that the BRAM->LUT arc's net delay falls toward Vivado's 3.146 ns.
# Check the "Net ... budget" lines in the critical path report, not just Fmax.
#
# Runs sequentially: each needs 6-8 GB and the machine has 13.9 GB total.
#
# Usage:  ./run_region_experiment.sh
set -euo pipefail

cd "$(dirname "$0")"

NEXTPNR="${NEXTPNR:-/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx}"
PART="${PART:-xc7k325tffg676-1}"
CHIPDB="${CHIPDB:-$PWD/chipdb/$PART.bin}"
XDC="${XDC:-../xdc/qmtech_xc7k325t_pinout.xdc}"
FREQ="${FREQ:-133.33}"
OUT=out_nm1_nosr
SRC="$OUT/am01_qmtech_top_st.json"

# Pin the distance model explicitly rather than inheriting it. This is the whole
# reason the archived pair is uninterpretable.
export NEXTPNR_ISO_HEURISTIC=1

for f in "$NEXTPNR" "$CHIPDB" "$SRC" "$XDC" "$OUT/cell_rounds.json"; do
    [ -e "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

run() {
    local tag="$1"; shift
    echo "==> $tag -- $(date -Is)"
    "$NEXTPNR" --chipdb "$CHIPDB" \
        --json "$SRC" --xdc "$XDC" \
        --fasm "$OUT/am01_qmtech_top_$tag.fasm" --freq "$FREQ" \
        --write "$OUT/placed_$tag.json" \
        --log "$OUT/am01_qmtech_top_$tag.pnr.log" "$@" || true
    echo "    $tag finished -- $(date -Is)"
    # nextpnr exits 0 even when it abandons arcs, so the log is the only source
    # of truth for whether this run is usable at all.
    grep -E "unrouted=[0-9]+" "$OUT/am01_qmtech_top_$tag.pnr.log" | tail -1 || true
    grep "clk_h" "$OUT/am01_qmtech_top_$tag.pnr.log" | grep MHz | tail -1 || true
}

run base_ctl
run rgn --pre-place preplace_round_regions.py

echo
echo "=== comparison ==="
for tag in base_ctl rgn; do
    printf "%-10s " "$tag"
    grep "clk_h" "$OUT/am01_qmtech_top_$tag.pnr.log" 2>/dev/null | grep MHz | tail -1 || echo "(no result)"
done
echo "archived striped baseline: 102.15 MHz (env unknown -- that is why base_ctl exists)"
