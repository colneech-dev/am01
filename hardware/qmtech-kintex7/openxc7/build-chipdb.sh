#!/usr/bin/env bash
# Generate a nextpnr-xilinx chipdb for the XC7K325T-FFG676 (this board's
# chip) from openXC7's prjxray-db, because no prebuilt one ships anywhere.
#
# Why this script exists: apio's `openxc7` package ships prebuilt chipdbs
# for Artix-7 / Spartan-7 / Zynq-7 ONLY -- there is no Kintex-7 binary in
# it, despite openXC7's docs listing Kintex7 (70T/160T/325T/420T/480T) as
# supported. The support is real, but you have to build the chipdb
# yourself from openXC7's prjxray-db fork, which does carry fuzzed
# kintex7 data including xc7k325tffg676-1. That's what this does.
#
# Verified working: see ./README.md -- the chipdb this produces takes a
# real design all the way to a valid .bit for xc7k325tffg676-1.
#
# Cost: ~8 min CPU, ~1.9GB peak disk (1.3GB intermediate .bba + 462MB
# final .bin), ~4GB RAM. The .bin is the only output you need to keep.
set -euo pipefail

DEVICE="${DEVICE:-xc7k325tffg676-1}"
OUT_DIR="${OUT_DIR:-$PWD/chipdb}"
SRC_DIR="${SRC_DIR:-$PWD/.openxc7-src}"
NEXTPNR_TAG="${NEXTPNR_TAG:-0.9.2}"

# bbasm turns the .bba text export into the binary chipdb. Any bbasm
# works (it is a dumb assembler); apio ships one, or build from source.
BBASM="${BBASM:-$(command -v bbasm || echo /root/.apio/packages/openxc7/bin/bbasm)}"

echo "==> device      : $DEVICE"
echo "==> output dir  : $OUT_DIR"
echo "==> bbasm       : $BBASM"

if [ ! -x "$BBASM" ]; then
    echo "ERROR: no bbasm found. Install apio's openxc7 package (pip install apio;"
    echo "       apio install system) or build nextpnr-xilinx and set BBASM=..."
    exit 1
fi

mkdir -p "$OUT_DIR" "$SRC_DIR"

# We only need the repo for xilinx/python/bbaexport.py plus its two
# submodules (prjxray-db for the fuzzed device data, nextpnr-xilinx-meta
# for site metadata). No compilation needed for chipdb generation.
if [ ! -d "$SRC_DIR/nextpnr-xilinx/.git" ]; then
    echo "==> cloning nextpnr-xilinx ($NEXTPNR_TAG) + submodules"
    git clone --depth 1 --branch "$NEXTPNR_TAG" \
        https://github.com/openXC7/nextpnr-xilinx.git "$SRC_DIR/nextpnr-xilinx"
    git -C "$SRC_DIR/nextpnr-xilinx" submodule update --init --recursive --depth 1 \
        xilinx/external/prjxray-db xilinx/external/nextpnr-xilinx-meta
fi

PYDIR="$SRC_DIR/nextpnr-xilinx/xilinx/python"

# bbaexport.py picks the right prjxray-db/metadata family automatically
# from the device name (it string-matches "xc7k" -> kintex7 etc), so the
# artix7 defaults in its --xray/--metadata flags are fine to leave alone.
echo "==> exporting .bba (this is the slow part, ~7-8 min)"
( cd "$PYDIR" && python3 bbaexport.py --device "$DEVICE" --bba "$OUT_DIR/$DEVICE.bba" )

echo "==> assembling binary chipdb"
"$BBASM" -l "$OUT_DIR/$DEVICE.bba" "$OUT_DIR/$DEVICE.bin"

rm -f "$OUT_DIR/$DEVICE.bba"   # 1.3GB intermediate, not needed once assembled

echo
echo "==> done: $OUT_DIR/$DEVICE.bin"
ls -la "$OUT_DIR/$DEVICE.bin"
echo
echo "NOTE: 'nextpnr-xilinx --chipdb <file> --test' reports a"
echo "      'bel == bel2' assertion failure on chipdbs generated this way."
echo "      That self-check appears to be broken/too strict rather than the"
echo "      chipdb being bad -- the same chipdb places, routes and produces a"
echo "      valid bitstream. See README.md 'The --test red herring'."
