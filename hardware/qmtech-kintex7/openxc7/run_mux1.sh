#!/usr/bin/env bash
# ONE miner built from the mux2-transformed core, in the OPEN-SOURCE flow.
#
# WHY. openXC7 tops out at one miner: the two-miner case was closed as not
# achievable here because the design sits at 840/890 RAMB18 (94%) and the
# floorplan BEL-pins every one of them, so the spreader cannot move anything.
# BRAM saturation is the blocker, not logic.
#
# mux2_transform.py collapses each PAIR of large S-box slots that read the same
# table into ONE block RAM, time-multiplexed on clk_2x. That halves BRAM per
# instance:
#
#     stock  1 instance x 420 RAMB18 = 420 of 890  (47%)
#     mux2   1 instance x 210 RAMB18 = 210 of 890  (24%)
#
# At 24% the BRAM pressure that blocks a second miner is simply gone. So this
# single-instance build is the cheap feasibility test for the thing that would
# actually close the gap to Vivado: TWO muxed miners at 420 RAMB18 (47%), which
# would take openXC7 from ~49 MH/s to roughly double that.
#
# WHAT TO READ OUT. Not the hashrate -- one muxed miner is SLOWER than one
# stock miner, because clk_2x has to close at 2 x clk_h. The numbers that
# matter are (a) does it fit and infer 210 RAMB18, (b) does it route at all,
# and (c) what clk_h can it hold. Vivado's own note on this transform expects
# clk_h to fall: routing alone is 3.201ns of the 4.055ns critical path in the
# 200MHz build, against a 2.5ns clk_2x budget.
#
# CAVEAT, stated up front: openxc7/README.md records that nextpnr cannot time
# paths adjacent to a block RAM on this arch -- which is exactly what the muxed
# address path is. So a clk_h number from this flow is NOT authoritative for
# the muxed path; fit and routability are what this run can honestly establish.
#
# The floorplan is OFF (BRAM_FP=0). It exists to place 840 BRAMs in a saturated
# device; at 210 it would be imposing a layout designed for a different problem.
set -uo pipefail
cd "$(dirname "$0")"
REPO=$(cd ../../.. && pwd)
HDL=$REPO/hardware/qmtech-kintex7/hdl
ODO=$REPO/hdl/odocrypt

OUT="${OUT:-out_mux1}"
FREQ="${FREQ:-133.33}"
XDC="${XDC:-$REPO/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc}"

echo "=== mux1: one mux2-transformed miner, FREQ=$FREQ -- $(date -Is) ==="
mkdir -p "$OUT"

SRL=0 FREQ="$FREQ" DEFINES=NO_XADC BRAM_OUTREG=0 BRAM_FP=0 \
    XDC="$XDC" \
    bash build.sh am01_qmtech_top_mux1 "$OUT" \
    "$HDL/mux4/encrypt_mux2.v" \
    "$ODO/keccak800.v" \
    "$HDL/mux4/cmp_256.v" \
    "$HDL/mux4/miner_mux4.v" \
    "$ODO/atomminer_misc.v" \
    "$HDL/clk_gen_hash.v" \
    "$HDL/found_path.v" \
    "$HDL/uart_bridge.v" \
    "$HDL/mux4/odocrypt_gpio_wrapper_mux4.v" \
    gen/mux1/am01_qmtech_top_mux1.v > "$OUT/build.log" 2>&1
echo "    build.sh exit $? -- $(date -Is)"

echo
echo "=== BRAM inference (the first question: does the transform hold?) ==="
grep -aE "RAMB18|RAMB36" "$OUT/build.log" | tail -5
echo
echo "=== timing ==="
grep -a "Max frequency for clock" "$OUT/am01_qmtech_top_mux1.pnr.log" 2>/dev/null | tail -3
echo "=== final route state ==="
grep -a "iter=" "$OUT/am01_qmtech_top_mux1.pnr.log" 2>/dev/null | tail -1
