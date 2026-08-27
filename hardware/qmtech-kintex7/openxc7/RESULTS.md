# Routed results — openXC7 flow, xc7k325t, OdoCrypt NUM_MINERS=1

All figures are **routed** `clk_h`, not post-place estimates. Those two diverge
badly on this design (118.20 estimated vs 89.30 routed on the baseline), and
reading an estimate as a result is the single most repeated error in this work.

Target **133.33 MHz**. Vivado place+route on the same netlist: **158.81 MHz**.

| config | routed clk_h | converged | vs baseline |
|---|---|---|---|
| baseline (no floorplan, no knobs) | 89.30 | iter 45 | — |
| `HPWL_SCALE_FIX` | 84.42 | iter 46 | −5.5% |
| BRAM floorplan alone (`vfp`) | 86.73 | iter 9 | −2.9% |
| floorplan 2 cols + `CRIT_DIST` | 91.12 | iter 23 | +2.0% |
| floorplan + `CRIT_DIST` + `SMALL_BETA` | 92.40 | iter 36 | +3.5% |
| floorplan 3 cols + `CRIT_DIST`, y-base 0 | 93.28 | iter 34 | +4.5% |
| **y-base 53** (Vivado's row range) | **112.11** | iter 23 | **+25.5%** |
| **y-base 40** | **122.40** | **iter 15** | **+37.1%** |

## What actually mattered

**BRAM row placement, by a wide margin.** Column count is worth ±2 MHz (2 and 4
cols/round both measured worse than 3). The row range is worth **+29 MHz**.

Mechanism: BRAM nets are 10.7% of nets but **42.5% of total HPWL** — median span
124 tiles against 1 for SLICE nets. The device edges are where clock regions
terminate and routing thins out. Packing BRAMs from Y0 puts them there; every
edge-adjacent BRAM pays on the nets that matter most.

**Neither half works alone.** The floorplan alone is *worse* than baseline
(86.73). `CRIT_DIST_EXP` alone never converged at all — it sat at ~1595 overused
across every arc budget and both seeds tried. They compose because they fail for
opposite reasons: `CRIT_DIST_EXP` corrects a real inversion in HeAP's
bound2bound weight (`1/(users*distance)` gives a die-crossing critical net LESS
pull than a 5-tile slack net) and pays for it by lengthening everything else
until the router drowns; the floorplan hands that routing budget back.

**Convergence improved alongside frequency**, which is the opposite of the
tradeoff every placer knob forced earlier: 45 iterations at baseline, 34 at
y-base 0, 23 at 53, **15 at 40**. Shorter BRAM nets make the design both faster
and easier to route.

**Copying Vivado got most of the way; tuning past it was better.** Vivado uses
Y53–137. y-base 53 gives 112.11, y-base 40 gives 122.40. The optimum is below
Vivado's own value, so the layout was a starting point rather than a target.

## Reproducing

`build.sh` defaults to this configuration:

    BRAM_FP=1  BRAM_YBASE=40  CRIT_DIST=1.0
    NEXTPNR_ARC_MAX_VISIT=2000000  NEXTPNR_ROUTER2_MAX_STALL=250

The router settings are part of the result, not incidental: 200k hard-errors on
this design's BRAM-egress arcs, the code default of unbounded oscillates and
never converges, and the default `MAX_STALL` of 50 counts iterations since the
BEST overuse improved, so it kills runs mid-descent.

## Not reproducible across epochs

Every figure above was measured on OdoCrypt epoch **1786752000**. The epoch
rotates every 10 days and changes S-box contents, though not the structure
(30 sbox_large, 22 full_round, 420 RAMB18E1 are unchanged), so the floorplan
carries over. Re-baseline before comparing across an epoch boundary.
