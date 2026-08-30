#!/usr/bin/env bash
# Quick runner for criticality knob tests (T6, T7, T8)
#
# Uses the reference baseline (seed 7, striped) by default.
# Usage:
#   ./test_t6_t7_t8.sh                    # use baseline placed.json
#   ./test_t6_t7_t8.sh /path/to/placed.json
#
# Results go to ./test_results/test_t*.log

set -euo pipefail

BASELINE="${1:-out_nm1_nosr/placed_st.json}"
OUTDIR="test_results"

if [ ! -f "$BASELINE" ]; then
    echo "ERROR: Baseline placement not found: $BASELINE" >&2
    echo "Available:" >&2
    ls -1 out_nm1_nosr/placed*.json 2>/dev/null | sed 's/^/  /' >&2
    exit 1
fi

echo "=== Running T6/T7/T8 criticality tests ==="
echo "Baseline: $BASELINE"
echo "Output:   $OUTDIR"
echo

mkdir -p "$OUTDIR"

# Source the test runner
"$(dirname "$0")/test_criticality_knobs.sh" "$BASELINE" am01_qmtech_top "$OUTDIR"

echo "=== Results ==="
for f in "$OUTDIR"/test_t*.log; do
    [ -f "$f" ] || continue
    echo "--- $(basename $f) ---"
    grep -E "(PASS|FAIL|clk_h|iter=)" "$f" | tail -4
done
