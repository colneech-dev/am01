#!/usr/bin/env bash
# Finish a build from an existing FASM: fasm -> frames -> .bit.
#
# WHY THIS EXISTS
# ---------------
# build.sh's timing gate read the POST-PLACEMENT report rather than the final
# post-route one, so it refused to emit a bitstream for a design that MEETS
# timing (noabs seed 2: placement estimate 130.89 FAIL, final 137.49 PASS).
# nextpnr had already written a complete 63 MB FASM before the gate fired.
#
# The gate is fixed, but re-running build.sh would repeat a ~40 minute route to
# regenerate a FASM that already exists and is known good. This finishes the job
# from the artefact on disk.
#
# Also useful whenever a route is worth keeping but the flow stopped after it.
#
# Usage:  fasm_to_bit.sh <outdir> [top]
set -euo pipefail
cd "$(dirname "$0")"

OUT="${1:?usage: fasm_to_bit.sh <outdir> [top]}"
TOP="${2:-am01_qmtech_top}"
PART="${PART:-xc7k325tffg676-1}"
PRJXRAY_DB="${PRJXRAY_DB:-$PWD/.openxc7-src/nextpnr-xilinx/xilinx/external/prjxray-db}"

. "$(dirname "$0")/toolchain.sh"
resolve_tool FASM2FRAMES   fasm2frames   || true
resolve_tool XC7FRAMES2BIT xc7frames2bit || true
for t in FASM2FRAMES:"$FASM2FRAMES" XC7FRAMES2BIT:"$XC7FRAMES2BIT"; do
    n=${t%%:*}; p=${t#*:}
    [ -n "$p" ] && [ -x "$p" ] || { echo "ERROR: $n not found (${p:-<unset>})"; exit 1; }
done

[ -s "$OUT/$TOP.fasm" ] || { echo "ERROR: no FASM at $OUT/$TOP.fasm"; exit 1; }

# Same BRAM-content check build.sh makes. A truncated FASM still yields a
# full-size .bit with every sbox ROM absent -- there is one such file in this
# tree, 11.4 MB with ZERO INIT lines, indistinguishable by size from a good one.
_expect=$(grep -c 'RAMB18E1' "$OUT/$TOP.json" 2>/dev/null || echo 0)
_got=$(grep -c 'INIT_[0-9A-F][0-9A-F]\[' "$OUT/$TOP.fasm" 2>/dev/null || echo 0)
echo "    BRAM cells in netlist: $_expect,  INIT lines in FASM: $_got"
if [ "$_expect" -gt 0 ] && [ "$_got" -eq 0 ]; then
    echo "ERROR: FASM carries no BRAM INIT lines -- the sbox ROMs would be empty."
    exit 1
fi

rm -f "$OUT/$TOP.frames" "$OUT/$TOP.bit"

echo "==> fasm -> frames -- $(date -Is)"
"$FASM2FRAMES" --part "$PART" --db-root "$PRJXRAY_DB/kintex7" \
    "$OUT/$TOP.fasm" > "$OUT/$TOP.frames"

# An empty frames file still yields a file(1)-valid bitstream, so file(1) proves
# the toolchain ran, not that the design is in it. Check the frames.
[ -s "$OUT/$TOP.frames" ] || { echo "ERROR: frames file is empty"; exit 1; }
echo "    frames: $(wc -l < "$OUT/$TOP.frames") lines"

echo "==> frames -> bitstream -- $(date -Is)"
"$XC7FRAMES2BIT" --part_file "$PRJXRAY_DB/kintex7/$PART/part.yaml" \
    --part_name "$PART" \
    --frm_file "$OUT/$TOP.frames" \
    --output_file "$OUT/$TOP.bit"

echo
ls -l "$OUT/$TOP.bit"
file "$OUT/$TOP.bit"
echo "==> done -- $(date -Is)"
