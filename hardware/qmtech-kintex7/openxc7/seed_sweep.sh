#!/bin/bash
# Seed sweep on the validated v26 configuration.
#
# WHY: the outcome is extremely placement-sensitive -- seed 7 gives 17 unrouted
# arcs, seed 1 gives 1140. Two orders of magnitude from one integer. Every seed
# comparison attempted before this was confounded (broken settings guard, the
# --placer-heap-beta fix changing run semantics mid-sweep, or a different
# binary), so there is no clean seed data at all.
#
# The coarse global router placed 251542 arcs with ZERO congested edges, so the
# fabric can carry this design; whether a given PLACEMENT can is the open
# question. Sampling placements is therefore the highest-value cheap experiment,
# and it is what commercial flows do -- Vivado ships multiple placement
# directives precisely because closure is placement-sensitive.
#
# FREE DIAGNOSTIC: record which nets fail per seed. If the same nets fail across
# every seed, the failure is structural and demand reduction (BRAM->LUT) is
# required. If the failing set moves, it is placement luck and picking a seed is
# the answer. That settles a question this project has been circling for days.
#
# Config below is v26 exactly -- the only variable is --seed (and --placer for
# the SA arm). Do NOT pass --placer-heap-beta: v26 passed 0.6 but the flag was
# being discarded, so it effectively ran at the arch default 0.4. Now that the
# flag works, passing it would change the placement and break comparability.

set -u
cd "$(dirname "$0")"

NPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=chipdb/xc7k325tffg676-1.bin
JSON=out_nm1_nosr/am01_qmtech_top.json
XDC=../xdc/qmtech_xc7k325t_pinout.xdc

export NEXTPNR_SKIP_FAILED_ARCS=1
export NEXTPNR_ARC_MAX_VISIT=200000
export NEXTPNR_REQUEUE_UNROUTED=1
export NEXTPNR_ARC_RETRY_BACKOFF=1
export NEXTPNR_CONG_GROWTH=1.3
export NEXTPNR_CONG_CLAMP=1000
export NEXTPNR_HIST_DECAY=0.9
export NEXTPNR_DIVERSIFY_RETRY=1
export NEXTPNR_ARC_VISIT_ESCALATE=1

run() {
    local tag="$1"; shift
    "$NPNR" --chipdb "$CHIPDB" --json "$JSON" --xdc "$XDC" \
        --fasm "out_nm1_nosr/am01_qmtech_top_${tag}.fasm" \
        --freq 133.33 --log "out_nm1_nosr/am01_qmtech_top_${tag}.pnr.log" \
        "$@" > "build_nosr_pnr_${tag}.log" 2>&1
    echo "${tag} EXIT=$? $(grep -o 'unrouted=[0-9]*' "out_nm1_nosr/am01_qmtech_top_${tag}.pnr.log" | tail -1) \
$(grep -o 'overused=[0-9]*' "out_nm1_nosr/am01_qmtech_top_${tag}.pnr.log" | tail -1)" >> sweep_results.txt
}

# results appended per-run; do not truncate (parallel runs would clobber)
run "$1" "${@:2}"
