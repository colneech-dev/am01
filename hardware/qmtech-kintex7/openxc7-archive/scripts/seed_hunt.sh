#!/usr/bin/env bash
# Sequential seed sweep on the y-base 40 BRAM floorplan, hunting for >= 133.33 MHz.
#
# WHY SEEDS
# ---------
# Measured spread on this exact configuration:
#     seed 7        114.03 MHz
#     seed default  122.40 MHz
#     seed 3        129.79 MHz
# ~16 MHz of seed variance, which is WIDER than most of the parameter
# differences ranked earlier today (y-base 30/40/46/53 spanned 108-122). So
# single-run parameter comparisons in that range were largely inside the noise,
# and seed choice is currently the strongest lever available.
#
# 129.79 is 97% of the 133.33 target. Seed sweeping is standard practice in FPGA
# flows, not a fudge -- the placement is deterministic per seed, so a seed that
# crosses is reproducible.
#
# Each run writes a FASM, so a seed that meets timing yields a usable bitstream
# directly.
#
# WHY SEQUENTIAL
# --------------
# Three concurrent nextpnr runs took free memory from 9 GB to 2 GB earlier, and
# there is an OOM kill (exit 137) on record in this project. One at a time is
# slower but cannot lose the whole sweep.
#
# Waits on ARTEFACTS (log has 4 "Max frequency" lines = routed, or an error),
# never on pgrep/pkill -- those match the checking command's own command line
# and have killed parent shells here.
set -euo pipefail

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
JSON=out_nm1_nosr/am01_qmtech_top_vy40.json
OUT=out_nm1_nosr
TARGET=133.33

done_for() {   # $1 = seed ; 0 = finished (routed or errored)
    local f="$OUT/am01_qmtech_top_vy40_seed$1.pnr.log"
    [ -e "$f" ] || return 1
    local n; n=$(grep -ac "Max frequency" "$f" 2>/dev/null || echo 0)
    [ "$n" -ge 4 ] && return 0
    grep -qa "ERROR" "$f" 2>/dev/null && return 0
    return 1
}

freq_of() {
    grep -a "clock   'clk_h'" "$OUT/am01_qmtech_top_vy40_seed$1.pnr.log" 2>/dev/null \
        | tail -1 | grep -oE "[0-9]+\.[0-9]+" | head -1
}

# Let the in-flight seeds finish before adding load.
echo "== waiting for in-flight seeds (1 11 23) =="
deadline=$(( $(date +%s) + 6*3600 ))
for s in 1 11 23; do
    while ! done_for "$s"; do
        [ "$(date +%s)" -gt "$deadline" ] && { echo "   timeout waiting on seed $s"; break; }
        sleep 60
    done
    echo "   seed $s: $(freq_of "$s" || echo '-') MHz"
done

for S in 2 5 13 17 19 29 31 37 42 99; do
    if done_for "$S"; then
        echo "== seed $S already done: $(freq_of "$S") MHz =="
        continue
    fi
    echo
    echo "== seed $S =="
    NEXTPNR_ARC_MAX_VISIT=2000000 NEXTPNR_ROUTER2_MAX_STALL=250 \
    NEXTPNR_CRIT_DIST_EXP=1.0 "$NEXTPNR" \
        --chipdb "$CHIPDB" --json "$JSON" --xdc "$XDC" \
        --freq 133.33 --seed "$S" \
        --write "$OUT/placed_vy40_seed$S.json" \
        --fasm "$OUT/am01_qmtech_top_vy40_seed$S.fasm" \
        --log "$OUT/am01_qmtech_top_vy40_seed$S.pnr.log" \
        > "vy40_seed$S.console.log" 2>&1 || echo "   seed $S exited non-zero"
    f=$(freq_of "$S" || true)
    echo "   seed $S -> ${f:-none} MHz"
    if [ -n "${f:-}" ] && awk "BEGIN{exit !($f >= $TARGET)}"; then
        echo "   *** MEETS TARGET ($f >= $TARGET) -- FASM written ***"
    fi
done

echo
echo "=== seed sweep summary (y-base 40, CRIT_DIST_EXP=1.0) ==="
for S in 3 7 1 11 23 2 5 13 17 19 29 31 37 42 99; do
    f=$(freq_of "$S" || true)
    [ -n "${f:-}" ] && printf "  seed %-4s %s MHz\n" "$S" "$f"
done | sort -k3 -n -r
