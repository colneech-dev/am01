#!/usr/bin/env bash
# Generate a Kintex-7 block RAM timing database for nextpnr-xilinx.
#
# WHY THIS EXISTS
# ---------------
# prjxray-db ships no timing data for kintex7 at all (artix7 has 50 SDF
# files, zynq7 45, spartan7 44; kintex7 and virtex7 have zero). Checked
# against openXC7's db at HEAD and f4pga's -- none of them has it.
#
# And no family exposes a cell called RAMB18E1, which is what yosys emits.
# The RAMB18 timing IS measured, but it is buried under mode-suffixed
# names on the RAMBFIFO36E1 site:
#
#   RAMBFIFO36E1RAM_MODE_U_RAMB18TDP_U_DOA_REG_U_0_EN_ECC_READ_FALSE
#       (IOPATH CLKARDCLKU DOADOU (0.585::1.098)(1.353::2.454))
#   RAMBFIFO36E1RAM_MODE_U_RAMB18TDP_U_DOA_REG_U_1_EN_ECC_READ_FALSE
#       (IOPATH CLKARDCLKU DOADOU (0.204::0.327)(0.468::0.882))
#
# RAMB18TDP is RAMB18 true dual port -- two independent read ports, which
# is exactly how the OdoCrypt S-boxes use it. DOA_REG_U_0 is with the
# optional output register disabled, which is what a plain
# `q <= mem[addr]` infers. So the data is real fuzzed silicon measurement
# of the configuration this design actually uses; it was simply
# unreachable because nothing ever looks up "RAMB18E1".
#
# This script re-keys it under the cell names synthesis emits, and writes
# the same numbers out as a C++ header so arch.cc's block RAM timing is
# traceable to the database rather than hand-typed.
#
# HONEST LIMITS
# -------------
#  * The numbers are Artix-7, not Kintex-7. Both are 28nm 7-series, but
#    Artix-7 is the lower-performance member, so these are PESSIMISTIC for
#    Kintex-7. That is the safe direction, and far better than the status
#    quo of excluding block RAM from timing entirely. AMD publishes the
#    real Kintex-7 figures in DS182; if you can reach it (this container's
#    egress proxy blocks docs.amd.com and every datasheet mirror tried),
#    substitute TRCKO_DO / TRCKO_DO_REG / TRCCK_ADDR for -1 and re-run.
#  * Per-family constants, not per-tile fuzzed data. Engineering guidance,
#    not sign-off. Sign-off means Vivado.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DB="${PRJXRAY_DB:-$HERE/.openxc7-src/nextpnr-xilinx/xilinx/external/prjxray-db}"
SRC_FAMILY="${SRC_FAMILY:-artix7}"

[ -d "$DB/$SRC_FAMILY/timings" ] || {
    echo "ERROR: no source timing data at $DB/$SRC_FAMILY/timings"
    echo "       (run build-chipdb.sh first to clone prjxray-db)"
    exit 1
}

python3 "$HERE/../tools/make_bram_timing.py" \
    --src "$DB/$SRC_FAMILY/timings" \
    --out-db "$DB/kintex7/timings" \
    --out-header "$HERE/.openxc7-src/nextpnr-xilinx/xilinx/xc7_bram_timing.h" || exit 1

echo
echo "Next: rebuild nextpnr (./build-nextpnr-bramtiming.sh) so arch.cc picks"
echo "up the regenerated header, then rebuild the chipdb if you want the SDF"
echo "itself consumed (./build-chipdb.sh)."
