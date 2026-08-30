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
# RE-BASELINED 2026-08-30 from cb224b6 to afa4b22, once the display work and
# the six touch/LCD defects from the code review had landed and the tree was
# clean. The earlier note read:
# Verified correct: the working-tree wrapper was modified at 29/15:16, after
# base finished synthesising (28/21:15) and after noabs (29/09:46), so both
# were built from cb224b6 content.
RTL_PINNED_COMMIT=afa4b22

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

# ---------------------------------------------------------------- STALENESS
# UNPIN WHEN: the numbers this pin protects are no longer being compared
# against. Concretely, unpin once EITHER
#
#   (a) the concurrent wrapper work (display path, register map) has landed and
#       you are ready to spend one ~2 h synthesis re-measuring `base` on it, or
#   (b) the placement experiments (GROUPS=1, folded floorplan, cols_per_round)
#       are finished and the chosen configuration is being built for real.
#
# A pin is a debt, not a feature. Its whole purpose is to keep ONE comparison
# honest; past that it means shipping and tuning RTL that nobody is editing any
# more, and every later measurement inherits a design that has silently drifted
# from the branch.
#
# TO UNPIN: bump RTL_PINNED_COMMIT to the new baseline commit, `rm -rf
# gen/rtl_pinned`, then RE-MEASURE base and replace the reference numbers in
# RESULTS.md and AUDIT-BUILT-VS-TESTED.md. Do NOT carry the old figures
# (base median 114.81, noabs median 127.71 / best 160.93) across the change --
# rebuild the control. To drop pinning altogether, delete this file and pass
# the working-tree paths directly.
#
# The warning below exists because a comment is not a reminder: it prints on
# every run, so the debt is visible rather than forgotten.
if _behind=$(git -C "$_rtl_repo" rev-list --count "$RTL_PINNED_COMMIT"..HEAD 2>/dev/null); then
    if [ "${_behind:-0}" -gt 0 ]; then
        # Compare the EXTRACTED pinned content against the working tree
        # directly, rather than asking git. Two things make `git diff` the wrong
        # tool here: `git -C` resolves pathspecs in a way that misreported 5 of
        # 6 files as drifted when only 1 had changed, and core.autocrlf=true in
        # this repo means the LF blob and the CRLF worktree file differ as bytes
        # while being identical as source. Stripping CR answers the question the
        # warning is actually asking.
        _drift=0
        for _p in "${RTL_PINNED_PATHS[@]}"; do
            _w="$_rtl_repo/$_p"
            _q="$_rtl_dir/$(basename "$_p")"
            [ -f "$_w" ] && [ -f "$_q" ] || continue
            if ! diff -q <(tr -d '\r' < "$_q") <(tr -d '\r' < "$_w") >/dev/null 2>&1; then
                _drift=$((_drift+1))
                _drifted="${_drifted:+$_drifted }$(basename "$_p")"
            fi
        done
        echo "    NOTE: RTL pinned at $RTL_PINNED_COMMIT, $_behind commit(s) behind HEAD." >&2
        if [ "$_drift" -gt 0 ]; then
            echo "          $_drift of ${#RTL_PINNED_PATHS[@]} pinned sources differ from the tree: $_drifted" >&2
            echo "          Intentional -- see UNPIN WHEN in rtl_sources.sh. Once the placement" >&2
            echo "          experiments are done, re-baseline and re-measure base." >&2
        else
            echo "          No pinned source differs from the tree yet -- the pin is currently" >&2
            echo "          a no-op and can be removed as soon as nothing depends on it." >&2
        fi
    fi
fi

unset _p _f _w _q _behind _drift _drifted _rtl_dir _rtl_repo
