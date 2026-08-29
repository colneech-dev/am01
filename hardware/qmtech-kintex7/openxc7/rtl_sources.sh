#!/usr/bin/env bash
# Shared, PINNED RTL source list for openxc7 timing experiments.
#
# WHY PINNED, AND NOT THE WORKING TREE
# ------------------------------------
# This branch is worked on by more than one person at a time. Mid-experiment,
# odocrypt_gpio_wrapper.v gained 131 lines across 8 hunks (display path, register
# map) while base/noabs/outreg netlists were already synthesised and being
# routed. Any new synthesis from the working tree would therefore be measured
# against a different design, and the comparison would silently attribute that
# RTL change to whatever knob was under test.
#
# That is exactly the mistake that wasted the first A/B, where the epoch and the
# wrapper had both moved under a control taken days earlier. A number is only
# comparable to another number built from identical sources.
#
# So the sources are pinned to cb224b6 -- the commit whose content the current
# base and noabs netlists were synthesised from -- and copied into
# gen/rtl_pinned/. Nothing here reads the working tree, so concurrent edits by
# anyone else cannot perturb a measurement in flight.
#
# encrypt.v is deliberately NOT in this list. It is generated per experiment
# (gen/encrypt_base.v, gen/encrypt_outreg.v, gen/encrypt_outreg_e2.v) and each
# caller passes the variant it is testing as the last source.
#
# TO RE-BASELINE onto newer RTL (e.g. once the display work lands): re-extract
# gen/rtl_pinned/ at the new commit, note the new commit here, and RE-MEASURE
# base. Do not compare across the change -- rebuild the control.
#
# Usage:
#   . "$(dirname "$0")/rtl_sources.sh"
#   bash build.sh am01_qmtech_top "$OUT" "${RTL_SRCS[@]}" gen/encrypt_base.v

#
# Verified correct: the working-tree wrapper was modified at 29/15:16, after
# base finished synthesising (28/21:15) and after noabs (29/09:46), so both
# were built from cb224b6 content.
RTL_PINNED_COMMIT=cb224b6

# Paths as they appear in the commit, keyed by the basename used locally.
RTL_PINNED_PATHS=(
    "hardware/qmtech-kintex7/hdl/am01_qmtech_top_nm1.v"
    "hardware/qmtech-kintex7/hdl/clk_gen_hash.v"
    "hardware/qmtech-kintex7/hdl/odocrypt_gpio_wrapper.v"
    "hdl/odocrypt/atomminer_misc.v"
    "hdl/odocrypt/keccak800.v"
    "hdl/odocrypt/miner.v"
)

_rtl_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gen/rtl_pinned"
_rtl_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
mkdir -p "$_rtl_dir"

# Extract on demand rather than committing ~1900 duplicated lines of RTL. The
# commit hash is then the single source of truth, and the pin cannot drift from
# what it claims to be.
RTL_SRCS=()
for _p in "${RTL_PINNED_PATHS[@]}"; do
    _f="$_rtl_dir/$(basename "$_p")"
    if [ ! -s "$_f" ]; then
        git -C "$_rtl_repo" show "$RTL_PINNED_COMMIT:$_p" > "$_f" || {
            echo "ERROR: cannot extract $_p at $RTL_PINNED_COMMIT" >&2
            rm -f "$_f"
            return 1 2>/dev/null || exit 1
        }
        echo "    pinned $(basename "$_p") @ $RTL_PINNED_COMMIT"
    fi
    RTL_SRCS+=("$_f")
done
unset _p _f _rtl_dir _rtl_repo
