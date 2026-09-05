#!/usr/bin/env bash
# Run T6, T7, T8: test criticality-weighting in router2
#
# These are the RWRoute agent's top recommendations (after code review showed
# they already exist in this tree, env-gated and defaulting to off):
#
#   T6  NEXTPNR_LOG_CRIT_GAP=1
#       Is criticality meaningful? Reports routed/predicted delay ratio per iter.
#       During negotiation criticality comes from predictDelay (placement estimate)
#       since the router doesn't bind wires until overused==0. If the loop is open,
#       criticality is fiction.
#
#   T7  NEXTPNR_CRIT_WEIGHT=0.4..0.6
#       Criticality-weighted path cost. Scale delay vs congestion by how critical
#       the arc is. Exact PathFinder form:
#         cost = crit * delay + (1 - crit) * congestion
#       Not 1.0: arc_crit clamps to 1.0, so w=1.0 makes the most critical
#       arcs completely congestion-blind and prevents convergence.
#
#   T8  NEXTPNR_SHARE_EXP=1..3, default 2 (RWRoute's default)
#       Criticality-aware resource sharing. This design has ~7 sinks per net,
#       so every later arc is paid to detour into the existing branch. This design
#       has many critical arcs that are multi-sink nets, so the discount should
#       decay with criticality.
#         share = (1 + source_uses) ^ (1 - min(1, e * crit))
#       e=0 disables (bit-identical to before).
#
# All are off by default. All should be measured against a fixed baseline,
# one at a time. Watch `overused` as closely as `clk_h` -- preventing
# convergence is the pathological failure mode.
#
# USAGE
# -----
#   ./test_criticality_knobs.sh <baseline_ref.json> <top> <output_dir> <srcs...>
#
# where baseline_ref.json is a pre-placed JSON (e.g. out_nm1_nosr/placed.json)
# so we route the exact same placement as the reference. Baseline and all test
# runs are written to <output_dir>/test_t{6,7,8}_*.log

set -euo pipefail

if [ $# -lt 4 ]; then
    echo "Usage: $0 <baseline.json> <top> <output_dir> <src1.v> [more.v...]" >&2
    exit 1
fi

BASELINE_JSON="$1"
TOP="$2"
OUTDIR="$3"
shift 3
SRCS=("$@")

# Source the toolchain discovery
. "$(dirname "$0")/toolchain.sh"
resolve_tool NEXTPNR nextpnr-xilinx || {
    echo "ERROR: nextpnr-xilinx not found" >&2
    exit 1
}

[ -d "$OUTDIR" ] || mkdir -p "$OUTDIR"

# Helper: run nextpnr with a specific test knob
run_test() {
    local test_name="$1"
    local env_var="$2"
    local env_val="$3"
    local desc="$4"

    local logfile="$OUTDIR/test_${test_name}.log"
    echo "=== $test_name: $desc ===" | tee "$logfile"

    # Route the baseline placement with the test knob set
    export "$env_var=$env_val"
    if "$NEXTPNR" \
        --json "$BASELINE_JSON" \
        --chipdb chipdb/xc7k325tffg676-1.bin \
        --xdc "$(dirname "$0")/../../xdc/qmtech_xc7k325t_pinout.xdc" \
        --phys --route \
        >> "$logfile" 2>&1
    then
        echo "PASS" | tee -a "$logfile"
        grep -a "clk_h" "$logfile" | tail -1 | tee -a "$logfile"
        grep -a "iter=" "$logfile" | tail -1 | tee -a "$logfile"
    else
        echo "FAIL" | tee -a "$logfile"
        tail -20 "$logfile" | tee -a "$logfile"
    fi
    unset "$env_var"
    echo
}

echo "Criticality knob tests (T6/T7/T8)"
echo "Baseline: $BASELINE_JSON"
echo "Output: $OUTDIR"
echo

# T6: Gate test — is criticality meaningful?
run_test "t6_log_crit_gap" "NEXTPNR_LOG_CRIT_GAP" "1" \
    "Report routed/predicted delay ratio per iteration"

# T7: Criticality-weighted cost
echo "T7: criticality-weighted cost (try 0.4, then 0.6)"
run_test "t7_crit_weight_04" "NEXTPNR_CRIT_WEIGHT" "0.4" \
    "Scale congestion by (1 - criticality)"
run_test "t7_crit_weight_06" "NEXTPNR_CRIT_WEIGHT" "0.6" \
    "Scale congestion by (1 - criticality), higher weight"

# T8: Criticality-aware sharing
echo "T8: criticality-aware sharing exponent (try 1, 2, 3)"
run_test "t8_share_exp_1" "NEXTPNR_SHARE_EXP" "1" \
    "Reduce sharing discount on critical arcs, exponent 1"
run_test "t8_share_exp_2" "NEXTPNR_SHARE_EXP" "2" \
    "RWRoute default, exponent 2"
run_test "t8_share_exp_3" "NEXTPNR_SHARE_EXP" "3" \
    "Higher penalty for sharing on critical arcs, exponent 3"

echo "=== Summary ==="
echo "Results in $OUTDIR/test_t{6,7,8}_*.log"
echo "Gate: does T6 show routed/predicted ratio near 1.0 (criticality is real)?"
echo "Then: pick the best T7 and T8 settings, measure together"
