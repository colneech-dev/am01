#!/usr/bin/env bash
# Vivado-free build: Verilog -> .bit for the QMTECH XC7K325T board.
#
# Verified end-to-end on the smoke-test design in ./smoke-test/ (see
# README.md). Produces a file `file(1)` identifies as
#   "Xilinx BIT data ... for xc7k325tffg676-1"
#
# Usage:
#   ./build.sh <top_module> <output_dir> <src.v> [more.v ...]
# Env:
#   XDC        constraints file (default: <first src dir>/<top>.xdc)
#   CHIPDB     chipdb .bin (default: ./chipdb/xc7k325tffg676-1.bin)
#   PRJXRAY_DB prjxray-db root (default: ./.openxc7-src/nextpnr-xilinx/xilinx/external/prjxray-db)
#   FREQ       target MHz for timing analysis (default: 50)
#   NEXTPNR    nextpnr-xilinx binary -- build current HEAD yourself (see
#              README.md §2); apio's prebuilt binary is 79 commits behind
#              and hangs/fails-validity on this design. An earlier version
#              of this comment said the opposite -- that was wrong.
#   FLATTEN    1 (default) passes -flatten to synth_xilinx. Needed for any
#              design whose tristate drivers sit in a submodule rather than
#              at the top level -- see README.md "Tristates across a
#              hierarchy boundary". Costs time and RAM on big designs
#              (am01_qmtech_top: ~90s/1GB unflattened vs ~14min/11GB
#              flattened), so set FLATTEN=0 if your tristates are already
#              at the top level, or if you have none.
#
#   GROUPS     1 = derive a placement group for every cell from RTL
#              hierarchy and constrain each anchored group to a region
#              (default 0, unchanged behaviour). Without it the floorplan
#              reaches only pre-placed cells -- 420 of 69869 on this
#              design, 0.6%. Depth is chosen per-netlist, not hardcoded.
#              Only groups with an anchor are constrained, so on a design
#              with nothing pre-placed this does nothing and says so.
#
# router2 (the P&R phase's routing step) reads its own env vars directly
# -- nothing here needs to pass them through, just export before calling
# this script. See README.md "router2 bounded termination" for what they
# do and why you'd want NEXTPNR_SKIP_FAILED_ARCS=1 on a first attempt at
# a new/changed design:
#   NEXTPNR_ROUTER2_MAX_ITER   outer congestion-negotiation iteration cap
#                              (default 600 -- router2 itself gives up
#                              loudly past this, it does not hang forever)
#   NEXTPNR_ROUTER2_MAX_STALL  give up after this many iterations with no
#                              improvement in overused-wire count (default 50)
#   NEXTPNR_SKIP_FAILED_ARCS   accept a partial/overused route at the cap
#                              instead of erroring, so [3/4] and [4/4]
#                              still run -- useful to see whether the flow
#                              completes at all before waiting for full
#                              convergence. The resulting .bit is for
#                              inspection only, not for programming a board.
set -euo pipefail

TOP="${1:?usage: build.sh <top> <outdir> <src.v> [...]}"
OUT="${2:?usage: build.sh <top> <outdir> <src.v> [...]}"
shift 2
SRCS=("$@")
[ "${#SRCS[@]}" -gt 0 ] || { echo "no source files given"; exit 1; }

PART="${PART:-xc7k325tffg676-1}"
CHIPDB="${CHIPDB:-$PWD/chipdb/$PART.bin}"
PRJXRAY_DB="${PRJXRAY_DB:-$PWD/.openxc7-src/nextpnr-xilinx/xilinx/external/prjxray-db}"
XDC="${XDC:-$(dirname "${SRCS[0]}")/$TOP.xdc}"
# FREQ has no safe default. nextpnr's XDC support does not carry create_clock
# through to the real clock nets on this design -- xdc.cc binds the constraint to
# the net named in create_clock (sys_clk_50m), while the nets that actually carry
# clocks are bus_clk and clk_h. Neither gets a clkconstr, so common/timing.cc
# falls back to target_freq, i.e. exactly this value.
#
# So FREQ is not a hint here, it is THE timing constraint for every domain. A
# default of 50 meant running build.sh as documented signed the design off at
# 50 MHz and then clocked it at 133.33 on the board -- a silent wrong-results
# path reachable from the README command line.
if [ -z "${FREQ:-}" ]; then
    echo "ERROR: FREQ is not set, and there is no safe default."
    echo "       nextpnr times EVERY clock domain against --freq on this design"
    echo "       (the XDC create_clock does not reach bus_clk/clk_h), so a wrong"
    echo "       FREQ silently signs off at the wrong frequency."
    echo "       For this board:  FREQ=133.33 $0 ..."
    exit 1
fi
# NB: do NOT write these as YOSYS="${YOSYS:-$(command -v yosys)}". Under
# `set -e` a failing command substitution inside an assignment kills the
# script immediately -- so if the tool is not on PATH, build.sh exits 1
# having printed absolutely nothing, which is a miserable thing to debug.
# `|| true` keeps the assignment succeeding so the explicit check below
# can report which tool is missing.
# Prefer the locally built toolchain over whatever is on PATH.
#
# /opt/openxc7 ships yosys 0.62 and nextpnr 0.9.2, but openXC7's own
# toolchain-installer pins yosys v0.68 and nextpnr-xilinx 0.9.3 -- the installed
# copy was simply never refreshed. The local builds are those newer versions
# plus the patches in patches/ and patches-yosys/, so they are what this flow
# should use. An explicit YOSYS=/NEXTPNR= still wins.
#
# WARNING: switching yosys versions invalidates comparability with every
# measurement taken before 2026-08-22. v0.68 produces a different netlist from
# 0.62 on this design (~1500 fewer small LUTs, MUXF7 unchanged at ~292), so
# numbers such as the 102.15 MHz striped result cannot be compared across the
# boundary. Re-establish a baseline rather than carrying old figures forward.
LOCAL_YOSYS=/home/colin/src/yosys-upstream/build/yosys
LOCAL_NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
YOSYS="${YOSYS:-$( [ -x "$LOCAL_YOSYS" ] && echo "$LOCAL_YOSYS" || command -v yosys || true )}"
NEXTPNR="${NEXTPNR:-$( [ -x "$LOCAL_NEXTPNR" ] && echo "$LOCAL_NEXTPNR" || command -v nextpnr-xilinx || true )}"
FASM2FRAMES="${FASM2FRAMES:-$(command -v fasm2frames || true)}"
XC7FRAMES2BIT="${XC7FRAMES2BIT:-$(command -v xc7frames2bit || true)}"

for t in YOSYS:"$YOSYS" NEXTPNR:"$NEXTPNR" \
         FASM2FRAMES:"$FASM2FRAMES" XC7FRAMES2BIT:"$XC7FRAMES2BIT"; do
    name=${t%%:*}; path=${t#*:}
    [ -n "$path" ] && [ -x "$path" ] || {
        echo "ERROR: $name not found or not executable (${path:-<unset>})."
        echo "       Set $name=/path/to/tool, e.g. $name=/opt/openxc7/bin/${name,,}"
        exit 1
    }
done

for f in "$CHIPDB" "$XDC"; do
    [ -e "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done
[ -d "$PRJXRAY_DB/kintex7/$PART" ] || {
    echo "ERROR: no prjxray-db data at $PRJXRAY_DB/kintex7/$PART"; exit 1; }

mkdir -p "$OUT"

FLATTEN="${FLATTEN:-1}"
[ "$FLATTEN" = "1" ] && FLATTEN_ARG="-flatten" || FLATTEN_ARG=""

# Each phase is timestamped -- the P&R phase in particular can run from
# minutes to hours depending on design congestion (see README.md), and
# without a start time in the log there is no way to tell "still working"
# from "died silently" after the fact (this cost real time once already,
# when a Windows reboot killed a run mid-route with no timestamp to
# reconstruct how long it had actually been going).
echo "==> [1/4] synthesis (yosys)${FLATTEN_ARG:+ , flattened} -- $(date -Is)"
# With GROUPS=1, recover the RTL scope onto every cell before writing the JSON.
#
# Synthesis destroys cell provenance: after synth_xilinx -flatten only 2 of 70774
# cells on this design carry hdlname, because abc and the FF mapping create new
# cells without it. hdlname_recover derives each cell's scope from the names of
# the nets it touches, which do survive flattening. nextpnr then groups by that
# with no external tooling.
#
# Off by default: it only adds attributes, but keeping the default byte-identical
# means GROUPS=0 builds stay comparable with older ones.
if [ "${GROUPS:-0}" = "1" ]; then
    "$YOSYS" -p "synth_xilinx -top $TOP -family xc7 $FLATTEN_ARG; hdlname_recover; write_json $OUT/$TOP.json" "${SRCS[@]}"
else
    "$YOSYS" -p "synth_xilinx -top $TOP -family xc7 $FLATTEN_ARG -json $OUT/$TOP.json" "${SRCS[@]}"
fi

# Optional RTL-hierarchy floorplan. Opt-in: default behaviour is unchanged.
#
# Without it the floorplan can address only the cells something else has already
# constrained -- on this design 420 BRAMs out of 69869, i.e. 0.6%, with 99.4% of
# the netlist anonymous ($abc$...parse_blif$N LUTs, $auto$ff.cc:...$N FFs). That
# is the best available explanation for why so much placer tuning refuted: global
# cost knobs were being turned while almost the whole design floated free.
#
# GROUPS=1 derives a placement group for every cell from durable RTL hierarchy
# (100% coverage on this design) and confines each anchored group to a region.
# Keyed on RTL paths, NOT yosys cell names -- the latter are pure counters
# ($abc$493613$auto$blifparse.cc:557:parse_blif$493614) and two netlists differing
# by one unrelated gate share ZERO of them, so anything keyed on them dies at the
# next edit. See tools_name_churn_test.sh.
#
# Depth is chosen per-netlist by --auto rather than hardcoded, so this does not
# rot when the RTL gains a hierarchy level or get used on a different design.
#
# NOTE: groups are only CONSTRAINED where they have an anchor -- a cell already
# placed by something else. On this design those come from floorplan_stripe.py's
# BRAMs. A design with no pre-placed cells gets regions for nothing and this is a
# silent no-op, which the log will say plainly rather than implying it worked.
if [ "${GROUPS:-0}" = "1" ]; then
    # Native path: no scripts. yosys writes the RTL scope onto every cell
    # (hdlname_recover), nextpnr groups by it, chooses the grouping depth, and
    # derives each region from the chipdb (--floorplan-hierarchy).
    #
    # The synthesis step above adds hdlname_recover when GROUPS=1; nothing else
    # is needed here. The former pipeline --
    #     derive_cell_groups.py -> bake_regions_into_json.py -> --pre-place hook
    # -- is superseded and kept only as reference tooling.
    PNR_EXTRA=(--floorplan-hierarchy)
    [ -n "${GROUP_PAD:-}" ] && PNR_EXTRA+=(--floorplan-pad "$GROUP_PAD")
else
    PNR_EXTRA=()
fi

echo "==> [2/4] place & route (nextpnr-xilinx) -- $(date -Is)"
"$NEXTPNR" --chipdb "$CHIPDB" \
    --json "$OUT/$TOP.json" --xdc "$XDC" \
    --fasm "$OUT/$TOP.fasm" --freq "$FREQ" \
    ${PNR_EXTRA[@]+"${PNR_EXTRA[@]}"} \
    --log "$OUT/$TOP.pnr.log"
echo "    place & route finished -- $(date -Is)"

# nextpnr exits 0 even when it gives up on arcs: NEXTPNR_SKIP_FAILED_ARCS makes
# it accept a partial route, and xilinx/arch.cc returns result = true
# unconditionally for router2, so the router's outcome never reaches the exit
# status. `set -e` cannot save us. Check the log.
#
# This matters more than "some nets are missing". An unrouted arc into a LUT
# input makes fixupRouting drop that input from X_ORIG_PORT_*, and get_lut_init
# then emits the truth table WITHOUT it -- the LUT computes a cofactor. The
# bitstream loads and computes the wrong function, with no warning anywhere.
_unrouted=$(grep -c 'SKIP_FAILED_ARCS: failed to route' "$OUT/$TOP.pnr.log" || true)
if [ "$_unrouted" -gt 0 ]; then
    echo "ERROR: $_unrouted arc(s) left unrouted."
    echo "       Do NOT program the .bit that would come out of this. An unrouted"
    echo "       arc into a LUT input silently rewrites that LUT's truth table"
    echo "       (the input is dropped from INIT), so the design computes wrong"
    echo "       results rather than failing visibly."
    echo "       Set OPENXC7_ALLOW_UNROUTED=1 only for debug/visualisation builds."
    [ -n "${OPENXC7_ALLOW_UNROUTED:-}" ] || exit 1
    echo "       OPENXC7_ALLOW_UNROUTED set -- continuing anyway."
fi

# Timing. nextpnr reports FAIL at INFO level and does not escalate
# (timing_analysis is called with warn_on_failure = false), so this is the only
# place it becomes an error.
if grep -q 'FAIL at' "$OUT/$TOP.pnr.log"; then
    echo "ERROR: timing not met:"
    grep 'FAIL at' "$OUT/$TOP.pnr.log" | sed 's/^/       /'
    echo "       Set OPENXC7_ALLOW_TIMING_FAIL=1 to build anyway."
    [ -n "${OPENXC7_ALLOW_TIMING_FAIL:-}" ] || exit 1
    echo "       OPENXC7_ALLOW_TIMING_FAIL set -- continuing anyway."
fi

# Block RAM content. A truncated FASM (e.g. one that hit a hard error partway)
# still yields a full-size .bit -- there is one in this tree with ZERO INIT lines,
# 11.4 MB, indistinguishable by size from a good one. Every sbox ROM absent, and
# nothing in the flow noticed.
_expect_bram=$(grep -c 'RAMB18E1' "$OUT/$TOP.json" 2>/dev/null || echo 0)
_got_init=$(grep -c 'INIT_[0-9A-F][0-9A-F]\[' "$OUT/$TOP.fasm" 2>/dev/null || echo 0)
if [ "$_expect_bram" -gt 0 ] && [ "$_got_init" -eq 0 ]; then
    echo "ERROR: design has block RAM but the FASM contains no INIT_ lines."
    echo "       The bitstream would come out with every ROM zeroed."
    exit 1
fi
echo "    checks passed: 0 unrouted, timing met, $_got_init BRAM INIT lines"

# Remove any previous run's outputs before regenerating. Otherwise a failure
# between here and [4/4] leaves a stale .frames/.bit that looks like a fresh
# successful build.
rm -f "$OUT/$TOP.frames" "$OUT/$TOP.bit"

echo "==> [3/4] fasm -> frames -- $(date -Is)"
"$FASM2FRAMES" --part "$PART" --db-root "$PRJXRAY_DB/kintex7" \
    "$OUT/$TOP.fasm" > "$OUT/$TOP.frames"

# A 0-byte frames file still produces a bitstream that file(1) reports as
# "Xilinx BIT data ... for xc7k325tffg676-1", within 4 bytes of the size of
# a real one. So file(1) proves the toolchain RAN, not that the design is
# in the bitstream. Check the frames instead.
if [ ! -s "$OUT/$TOP.frames" ]; then
    echo "ERROR: $OUT/$TOP.frames is empty -- fasm2frames produced nothing."
    echo "       Do NOT trust the .bit that would come out of this: an empty"
    echo "       frames file still yields a file(1)-valid bitstream."
    exit 1
fi

echo "==> [4/4] frames -> bitstream -- $(date -Is)"
"$XC7FRAMES2BIT" --part_file "$PRJXRAY_DB/kintex7/$PART/part.yaml" \
    --part_name "$PART" \
    --frm_file "$OUT/$TOP.frames" \
    --output_file "$OUT/$TOP.bit"

echo
echo "==> done -- $(date -Is)"
ls -la "$OUT/$TOP.bit"
file "$OUT/$TOP.bit"
