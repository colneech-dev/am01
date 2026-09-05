#!/usr/bin/env bash
# Third in the chain: wait for the WIRE_DEMAND=1.0 route, then NEXTPNR_SMALL_BETA=0.4.
#
# WHY SMALL_BETA NEXT
# -------------------
# It ranked 4th on the placement screen (11646 / 4249226 against a
# 13045 / 4260448 baseline), behind CRIT_DIST_EXP, WIRE_DEMAND and
# HPWL_SCALE_FIX. But rank is not the reason it is queued: it is the only knob
# that targets the path limiting OUR flow.
#
# nextpnr's own 89.30 MHz run is limited by a BRAM output reaching its consumer
# LUT across (19,343) -> (50,151):
#
#   Source ...crypter.round17.sboxes.sbox14inst.mem.0.0.DOPADOP0   2.1 ns
#   Net    round17.mid[1][158]   8.8 ns
#   Sink   $abc$...$497312.A5
#
# (The 644-fanout crypt.progress[1] net is VIVADO's bottleneck on the same
# placement, not ours.)
#
# And beta provably never reaches block RAM. SpreaderRegion::overused()
# bypasses it for tiles with fewer than 4 bels:
#
#   if (bels.at(t) < 4) { if (cells.at(t) > bels.at(t)) return true; }
#   else                { if (cells.at(t) > beta * bels.at(t)) return true; }
#
# A BRAM/BRAM_L/BRAM_R tile holds 2 RAMB18E1 bels, so BRAM takes the first
# branch and its effective density target is 100% at EVERY beta. The spreader
# packs block RAM to full density in whichever columns the solver favoured and
# never relaxes. With 420 RAMB18E1 against 445 BRAM tiles there is room for one
# per tile; NEXTPNR_SMALL_BETA=0.4 gives bels=2 a target of 0.8, i.e. it trips
# at one cell and spreads.
#
# WHY NOT COMBINE IT WITH THE WINNER OF THE EARLIER RUNS
# ------------------------------------------------------
# Every combination measured worse than its better half alone:
#   CRIT_DIST_EXP + HPWL_SCALE_FIX  18027  vs 8685 and 11299
#   CRIT_DIST_EXP + SMALL_BETA      13600  vs 8685
# These knobs interact destructively. One at a time until a routed number says
# otherwise.
#
# WAITING ON AN ARTEFACT, NOT pgrep -- `pgrep -f <pattern>` matches the checking
# command's own command line, reports a phantom process and never returns. Six
# occurrences of that bug are on record in this project.
set -euo pipefail

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
JSON=out_nm1_nosr/am01_qmtech_top_v68.json
OUT=out_nm1_nosr

WAIT_FOR="$OUT/am01_qmtech_top_wd10.fasm"
PREV_LOG="$OUT/am01_qmtech_top_wd10.pnr.log"

echo "== waiting for $WAIT_FOR =="
deadline=$(( $(date +%s) + 10*3600 ))
while [ ! -e "$WAIT_FOR" ]; do
    if [ "$(date +%s)" -gt "$deadline" ]; then
        echo "TIMEOUT: $WAIT_FOR never appeared; predecessor likely stalled."
        grep -a 'iter=' "$PREV_LOG" 2>/dev/null | tail -1 || true
        echo "proceeding anyway -- the runs share no state."
        break
    fi
    sleep 60
done

echo "== predecessor result (WIRE_DEMAND=1.0) =="
grep -a "Max frequency for clock" "$PREV_LOG" 2>/dev/null | tail -2 || echo "  (none)"
grep -a 'iter=' "$PREV_LOG" 2>/dev/null | tail -1 || true

echo
echo "== NEXTPNR_SMALL_BETA=0.4, full place and route =="
NEXTPNR_SMALL_BETA=0.4 "$NEXTPNR" \
    --chipdb "$CHIPDB" \
    --json "$JSON" \
    --xdc "$XDC" \
    --freq 133.33 \
    --write "$OUT/placed_sb04.json" \
    --fasm "$OUT/am01_qmtech_top_sb04.fasm" \
    --log "$OUT/am01_qmtech_top_sb04.pnr.log"

echo "== routed result (compare against baseline 89.30 MHz) =="
grep -a "Max frequency for clock" "$OUT/am01_qmtech_top_sb04.pnr.log" | tail -2
grep -a 'iter=' "$OUT/am01_qmtech_top_sb04.pnr.log" | tail -1

echo
echo "== did BRAM actually spread? =="
echo "   (compare BRAM column spread against the baseline placement;"
echo "    the point of this knob is one RAMB18E1 per tile instead of two)"
