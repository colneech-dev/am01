#!/usr/bin/env bash
# Build nextpnr-xilinx with block RAM timing support.
#
# WHY THIS EXISTS
# ---------------
# Stock nextpnr-xilinx does not time block RAM. getPortTimingClass() in
# xilinx/arch.cc has cases for SLICE_LUTX, CARRY4, SLICE_FFX, the F7/F8/F9
# muxes, IOBs, BUFGCTRL and DSP48E1, and everything else -- RAMB18E1 and
# RAMB36E1 included -- falls through to `return TMG_IGNORE`. The string
# "RAMB" does not appear in the file at all. So a block RAM output is not
# a timing start point, its address inputs are not endpoints, and any
# critical path through a memory is invisible to the STA.
#
# On a design that is 420 block RAMs per hash instance, that makes the
# reported Fmax simply the worst LUT-to-LUT path: wrong, and optimistic.
#
# It is detectable this way: take a harness of BRAM -> 6-LUT-deep XOR fold
# -> flop, and insert a fabric register between the BRAM and the fold.
# Pipelining a long path should RAISE Fmax. Instead the reported figure
# collapsed, 840 MHz -> 197 MHz, because the register did not shorten
# anything -- it created a fabric-to-fabric path the tool could actually
# see, where the BRAM-fed path had been invisible. The 840 MHz was never
# the fold at all; it was the short address path, the only thing being
# timed.
#
# Note this is NOT fixable by supplying better timing data. prjxray-db has
# no kintex7 timing at all, and no family characterises RAMB18E1 (only the
# RAMBFIFO36E1 site) -- but even with perfect data the arch code never
# performs the lookup. The fix has to be in the C++.
#
# WHAT THE PATCH DOES
# -------------------
# patches/0001-xc7-block-ram-timing.patch teaches arch.cc to:
#   * classify RAMB ports (clocks, synchronous read outputs, sampled
#     inputs) instead of ignoring them, and
#   * return real BRAM setup/hold/clock-to-out instead of the flat 0.1 ns
#     that getPortClockingInfo hands every cell.
#
# Delay values are the slow-corner maxima from artix7's BRAM_L.sdf, the
# closest real 7-series data that exists. Artix-7 is the lower-performance
# family member, so they are pessimistic for Kintex-7 -- the safe
# direction. This is engineering guidance, not sign-off; sign-off needs
# Vivado, which does not cover this part for free.
#
#   ./build-nextpnr-bramtiming.sh [srcdir]
#
# Produces <srcdir>/nextpnr-xilinx/build/nextpnr-xilinx. Point build.sh at
# it with NEXTPNR=.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${1:-$HERE/.openxc7-src}"
REPO="$SRC_DIR/nextpnr-xilinx"
# Keep this identical to build-chipdb.sh: the chipdb encodes nextpnr's internal
# ID table, so the tree that generates it and the binary that reads it must be
# the same revision, or loading aborts with
#     internal IDs of nextpnr are inconsistent with the supplied chip database
#
# NEXTPNR_TAG is only a fallback for when there is no local tree. 0.9.2 cannot
# route -- it fails even the blinky smoke test, on a flip-flop output feeding a
# LUT input in the same slice -- so do not pin to it.
. "$(dirname "$0")/toolchain.sh"
LOCAL_NEXTPNR_SRC="${NEXTPNR_SRC:-}"
NEXTPNR_TAG="${NEXTPNR_TAG:-0.9.2}"
JOBS="${JOBS:-$(nproc)}"

if [ ! -d "$REPO/.git" ]; then
    echo "==> cloning nextpnr-xilinx ($NEXTPNR_TAG)"
    mkdir -p "$SRC_DIR"
    git clone --depth 1 --branch "$NEXTPNR_TAG" \
        https://github.com/openXC7/nextpnr-xilinx.git "$REPO"
fi

echo "==> applying block RAM timing patch"
if git -C "$REPO" apply --check "$HERE/patches/0001-xc7-block-ram-timing.patch" 2>/dev/null; then
    git -C "$REPO" apply "$HERE/patches/0001-xc7-block-ram-timing.patch"
    echo "    applied"
elif git -C "$REPO" apply --reverse --check "$HERE/patches/0001-xc7-block-ram-timing.patch" 2>/dev/null; then
    echo "    already applied, skipping"
else
    echo "ERROR: patch does not apply to this tree and is not already applied."
    echo "       The upstream arch.cc has probably moved on; re-diff it."
    exit 1
fi

# The patch adds #include "xc7_bram_timing.h", and that header is
# GENERATED from prjxray's SDF rather than checked in -- so it has to exist
# before the compiler sees arch.cc. Generating it here keeps the two in
# step; editing the numbers means re-running make-bram-timing-db.sh, not
# editing arch.cc.
HEADER="$REPO/xilinx/xc7_bram_timing.h"
if [ ! -f "$HEADER" ]; then
    echo "==> generating block RAM timing header (missing)"
    "$HERE/make-bram-timing-db.sh" || {
        echo "ERROR: could not generate $HEADER"
        echo "       run ./build-chipdb.sh first -- it clones the prjxray-db"
        echo "       that the timing numbers are extracted from."
        exit 1
    }
else
    echo "==> block RAM timing header present"
fi

echo "==> configuring"
mkdir -p "$REPO/build"
cmake -S "$REPO" -B "$REPO/build" \
    -DARCH=xilinx -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_GUI=OFF -DBUILD_PYTHON=OFF

echo "==> building with $JOBS jobs (this takes a while)"
make -C "$REPO/build" -j"$JOBS"

echo
echo "==> done: $REPO/build/nextpnr-xilinx"
"$REPO/build/nextpnr-xilinx" --version
echo
echo "Use it with:  NEXTPNR=$REPO/build/nextpnr-xilinx ./build.sh ..."
echo
echo "SANITY CHECK before trusting any number it prints. Insert a register"
echo "between a block RAM output and the logic it feeds. Pipelining a long"
echo "path SPLITS it, so the reported Fmax must RISE (or hold)."
echo
echo "  broken (BRAM paths untimed):  840.34 -> 197.43 MHz   Fmax FELL"
echo "  fixed  (this patch):          106.56 -> 162.50 MHz   Fmax rose"
echo
echo "A fall is the bug's signature: the register did not slow anything"
echo "down, it exposed a fabric-to-fabric path the tool could actually see,"
echo "where the BRAM-fed path had been invisible."
