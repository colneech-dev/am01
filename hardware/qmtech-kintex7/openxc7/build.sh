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
#   NEXTPNR    nextpnr-xilinx binary -- SEE THE WARNING IN README.md, use
#              apio's prebuilt one, not a from-source 0.9.2 build.
#   FLATTEN    1 (default) passes -flatten to synth_xilinx. Needed for any
#              design whose tristate drivers sit in a submodule rather than
#              at the top level -- see README.md "Tristates across a
#              hierarchy boundary". Costs time and RAM on big designs
#              (am01_qmtech_top: ~90s/1GB unflattened vs ~14min/11GB
#              flattened), so set FLATTEN=0 if your tristates are already
#              at the top level, or if you have none.
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
FREQ="${FREQ:-50}"
# NB: do NOT write these as YOSYS="${YOSYS:-$(command -v yosys)}". Under
# `set -e` a failing command substitution inside an assignment kills the
# script immediately -- so if the tool is not on PATH, build.sh exits 1
# having printed absolutely nothing, which is a miserable thing to debug.
# `|| true` keeps the assignment succeeding so the explicit check below
# can report which tool is missing.
YOSYS="${YOSYS:-$(command -v yosys || true)}"
NEXTPNR="${NEXTPNR:-$(command -v nextpnr-xilinx || true)}"
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

echo "==> [1/4] synthesis (yosys)${FLATTEN_ARG:+ , flattened}"
"$YOSYS" -p "synth_xilinx -top $TOP -family xc7 $FLATTEN_ARG -json $OUT/$TOP.json" "${SRCS[@]}"

echo "==> [2/4] place & route (nextpnr-xilinx)"
"$NEXTPNR" --chipdb "$CHIPDB" \
    --json "$OUT/$TOP.json" --xdc "$XDC" \
    --fasm "$OUT/$TOP.fasm" --freq "$FREQ" \
    --log "$OUT/$TOP.pnr.log"

echo "==> [3/4] fasm -> frames"
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

echo "==> [4/4] frames -> bitstream"
"$XC7FRAMES2BIT" --part_file "$PRJXRAY_DB/kintex7/$PART/part.yaml" \
    --part_name "$PART" \
    --frm_file "$OUT/$TOP.frames" \
    --output_file "$OUT/$TOP.bit"

echo
echo "==> done"
ls -la "$OUT/$TOP.bit"
file "$OUT/$TOP.bit"
