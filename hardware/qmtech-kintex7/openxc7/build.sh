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
YOSYS="${YOSYS:-$(command -v yosys)}"
NEXTPNR="${NEXTPNR:-$(command -v nextpnr-xilinx)}"

for f in "$CHIPDB" "$XDC"; do
    [ -e "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done
[ -d "$PRJXRAY_DB/kintex7/$PART" ] || {
    echo "ERROR: no prjxray-db data at $PRJXRAY_DB/kintex7/$PART"; exit 1; }

mkdir -p "$OUT"

echo "==> [1/4] synthesis (yosys)"
"$YOSYS" -p "synth_xilinx -top $TOP -family xc7 -json $OUT/$TOP.json" "${SRCS[@]}"

echo "==> [2/4] place & route (nextpnr-xilinx)"
"$NEXTPNR" --chipdb "$CHIPDB" \
    --json "$OUT/$TOP.json" --xdc "$XDC" \
    --fasm "$OUT/$TOP.fasm" --freq "$FREQ" \
    --log "$OUT/$TOP.pnr.log"

echo "==> [3/4] fasm -> frames"
fasm2frames --part "$PART" --db-root "$PRJXRAY_DB/kintex7" \
    "$OUT/$TOP.fasm" > "$OUT/$TOP.frames"

echo "==> [4/4] frames -> bitstream"
xc7frames2bit --part_file "$PRJXRAY_DB/kintex7/$PART/part.yaml" \
    --part_name "$PART" \
    --frm_file "$OUT/$TOP.frames" \
    --output_file "$OUT/$TOP.bit"

echo
echo "==> done"
ls -la "$OUT/$TOP.bit"
file "$OUT/$TOP.bit"
