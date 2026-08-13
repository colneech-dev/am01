#!/usr/bin/env bash
# Measure block RAM per encrypt core, stock vs shared-BRAM rewrite.
#
# This is the number the whole 4-instance plan rests on, so it is measured
# with yosys rather than reasoned about. Cheap: ~35 s and ~280 MB per core.
#
#   ./measure_bram.sh [workdir]
#
# Expected (XC7K325T, yosys 0.62, synth_xilinx -family xc7):
#
#   stock : 420 RAMB18E1   (21 full_round x 20 large S-boxes)
#   shared: 210 RAMB18E1   (21 full_round x 10 shared S-boxes)
#
# 210 per instance is what lets 4 instances fit in the device's 890
# RAMB18 (840, 94%) where 2 fit at 420 apiece.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ODO="$HERE/../../../exmaples/odocrypt/fpga/src/hdl"
WORK="${1:-${TMPDIR:-/tmp}/encrypt-bram}"
YOSYS="${YOSYS:-$(command -v yosys || echo /opt/openxc7/bin/yosys)}"
mkdir -p "$WORK" || exit 1

[ -x "$YOSYS" ] || { echo "ERROR: no yosys (set YOSYS=/path/to/yosys)"; exit 1; }

python3 "$HERE/mux2_transform.py" "$ODO/encrypt.v" "$WORK/encrypt_mux2.v" || exit 1

synth () {  # <label> <top> <src>
    echo "==> synthesising $1"
    local t0=$SECONDS
    "$YOSYS" -p "synth_xilinx -top $2 -family xc7" "$3" > "$WORK/synth_$1.log" 2>&1
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "    FAILED (exit $rc):"; tail -n 12 "$WORK/synth_$1.log" | sed 's/^/      /'
        return 1
    fi
    echo "    ok, $((SECONDS-t0))s"
}

synth stock  encrypt_4encrypt "$ODO/encrypt.v"       || exit 1
synth shared encrypt_4encrypt "$WORK/encrypt_mux2.v" || exit 1

# Pull the design-wide rollup (the "=== design hierarchy ===" section),
# not a per-module local count -- those look similar and mixing them up
# gives nonsense (a local FDRE count reads as if the flops vanished).
totals () {
    awk '/^=== design hierarchy ===/{f=1} f' "$WORK/synth_$1.log" \
      | grep -E "^ +[0-9]+ +(LUT[0-9]|RAMB18E1|RAMB36E1|CARRY4|MUXF[78])$"
}

echo
printf '%-10s %-12s %s\n' "" "stock" "shared"
for cell in RAMB18E1 RAMB36E1 LUT2 LUT3 LUT4 LUT5 LUT6; do
    a=$(totals stock  | awk -v c="$cell" '$2==c{print $1}'); a=${a:-0}
    b=$(totals shared | awk -v c="$cell" '$2==c{print $1}'); b=${b:-0}
    printf '%-10s %-12s %s\n' "$cell" "$a" "$b"
done

echo
echo "per shared S-box module (local count):"
awk '/^=== encrypt_4sbox_large0_mux2 ===/,/Estimated number of LCs/' \
    "$WORK/synth_shared.log" | grep -E "^ +[0-9]+ +(LUT[0-9]|RAMB18E1|FDRE)$" | sed 's/^/  /'
echo "per stock S-box module (local count):"
awk '/^=== encrypt_4sbox_large0 ===/,/Estimated number of LCs/' \
    "$WORK/synth_stock.log" | grep -E "^ +[0-9]+ +(LUT[0-9]|RAMB18E1|FDRE)$" | sed 's/^/  /'
