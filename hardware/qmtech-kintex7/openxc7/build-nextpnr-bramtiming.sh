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
# It is also detectable -- inserting a register into a BRAM-fed path, which
# can only ever shorten each path, made the reported frequency RISE from
# 197 MHz to 840 MHz. See README.md, "nextpnr's STA does not see block RAM
# paths".
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
echo "SANITY CHECK before trusting any number it prints: inserting a"
echo "register into a BRAM-fed path must NOT raise the reported Fmax."
echo "That inversion is the signature of the bug this patch fixes."
