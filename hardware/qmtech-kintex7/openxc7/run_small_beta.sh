#!/usr/bin/env bash
# Full place-and-route with NEXTPNR_SMALL_BETA=0.4.
#
# WHY THIS KNOB
# -------------
# It is the only lever that reaches the path limiting OUR flow. nextpnr's own
# 89.30 MHz baseline is set by a BRAM output reaching its consumer LUT across
# (19,343) -> (50,151):
#
#   Source ...crypter.round17.sboxes.sbox14inst.mem.0.0.DOPADOP0   2.1 ns
#   Net    round17.mid[1][158]   8.8 ns
#   Sink   $abc$...$497312.A5
#
# (The 644-fanout net is VIVADO's bottleneck on the same placement, not ours.)
#
# And beta provably never reaches block RAM. SpreaderRegion::overused() bypasses
# it for tiles with fewer than 4 bels, and a BRAM tile holds 2 RAMB18E1 bels, so
# block RAM sits at a 100% density target at EVERY beta. With 420 RAMB18E1
# against 445 BRAM tiles there is room for one per tile; SMALL_BETA=0.4 gives
# bels=2 a target of 0.8, so a tile trips at one cell and spreads.
#
# WHY IT IS RUN DIRECTLY RATHER THAN QUEUED
# -----------------------------------------
# It was queued behind WIRE_DEMAND=1.0, which was killed at router iteration 174
# without converging: overuse sat flat in the 16-33 band while wirelength climbed
# monotonically (1614221 -> 1614693), i.e. the router was adding resources
# without reducing congestion. No FASM is written unless a run converges, so the
# queue would have idled until its 10-hour timeout waiting for an artefact that
# was never coming.
#
# WHAT TO WATCH
# -------------
# 1. Convergence FIRST. Compare `overused` against the baseline at the SAME
#    iteration: 395 at iter 9, 60 at 17, 14 at 25, 1 at 41, 0 at 45. A run still
#    in the tens past iteration 60 is not converging, and its frequency would be
#    meaningless.
# 2. Then the ROUTED "Max frequency" line, against 89.30 MHz. Ignore the
#    post-place estimate entirely -- it read 118.20 on a baseline that routed to
#    89.30, and has been anti-correlated with the routed result on every
#    candidate measured so far.
# 3. Whether BRAM actually spread. "The knob changed the number" and "the knob
#    did what it claims" are different questions, and several mechanisms in this
#    tree turned out never to fire.
set -euo pipefail

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
JSON=out_nm1_nosr/am01_qmtech_top_v68.json
OUT=out_nm1_nosr

for f in "$NEXTPNR" "$CHIPDB" "$XDC" "$JSON"; do
    [ -e "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

echo "== NEXTPNR_SMALL_BETA=0.4, full place and route =="
NEXTPNR_ARC_MAX_VISIT=200000 NEXTPNR_SMALL_BETA=0.4 "$NEXTPNR" \
    --chipdb "$CHIPDB" \
    --json "$JSON" \
    --xdc "$XDC" \
    --freq 133.33 \
    --write "$OUT/placed_sb04.json" \
    --fasm "$OUT/am01_qmtech_top_sb04.fasm" \
    --log "$OUT/am01_qmtech_top_sb04.pnr.log"

echo "== routed result (baseline is 89.30 MHz) =="
grep -a "Max frequency for clock" "$OUT/am01_qmtech_top_sb04.pnr.log" | tail -2
grep -a 'iter=' "$OUT/am01_qmtech_top_sb04.pnr.log" | tail -1
