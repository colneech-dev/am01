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

---

# Target met — 2026-08-30

**`e2nbfix`: median 166.81 MHz, 5 of 5 seeds pass 133.33 MHz, worst case
149.28 (12% margin).** Every seed converged with `overuse=0 unrouted=0`.
Bitstream at `out_e2nb_fixed/am01_qmtech_top.bit`.

This is the first configuration for which all three hold at once: functionally
verified, timing-clean across seeds, and a bitstream exists.

## Configuration

| setting | value | why |
|---|---|---|
| `odo_gen --bram-out-reg` | on | second sbox register, 3 cycles/round |
| `extra_delay` | 2 (automatic, min 1) | relay in the recirculation path |
| `BRAM_OUTREG` | **0** | register stays in FABRIC — placeable, 0.1 ns |
| `BRAM_FP` / `BRAM_YBASE` | 1 / 40 | Vivado-measured BRAM rows |
| `CRIT_DIST` | 1.0 | |
| `SRL` / `DEFINES` | 0 / `NO_XADC` | prjxray has no XADC tile for this part |

| seed | clk_h | iters |
|---|---|---|
| 1 | 180.47 | 14 |
| 2 | 177.94 | 42 |
| 3 | 166.81 | 25 |
| 4 | 149.28 | 22 |
| 5 | 154.56 | 109 |
| (default) | 141.90 | — |

## Functional verification

`sim/tb_sched_equiv.v` under Verilator, comparing emitted result SEQUENCES
(latencies differ by design, 172 vs 259, so a cycle-wise diff is meaningless):

```
positive            PASS -- 440 results identical
negative brk=3      FAIL -- 23 of 25 differ
negative brk=10     FAIL -- 16 of 25 differ
negative brk=50     FAIL -- 391 of 440 differ
```

The controls are monotonic in the injection point, which is what makes the
positive trustworthy rather than merely clean.

## VOID — measured on a core that computed wrong digests

Every `--bram-out-reg` figure taken before commit `fbd6433` is invalid. The
round-key tap was `RoundCycles*i` when a two-register sbox needs
`RoundCycles*i + 1`, so every round key arrived one cycle early. The core ran
at full speed and produced wrong results — silent pool rejects, not a failure.

| variant | median | status |
|---|---|---|
| `outreg` | 82.90 | **VOID** |
| `noabs` | 127.71 | **VOID** |
| `e2` | 134.19 | **VOID** |
| `e2nb` | 158.23 | **VOID** — superseded by `e2nbfix` 166.81 |
| `base` | 114.81 | **valid** — reference core, byte-identical before and after the fix |

Notably the corrected core is *faster* than the broken one it replaced
(166.81 vs 158.23 median), so the fix cost nothing.

## What survives from the voided work

The placement conclusions, because they rest on critical-path structure —
source delays, logic-versus-routing splits, where paths terminate — rather
than on Fmax:

* **This design is wire-limited, not logic-limited.** Routing is ~70% of
  `base`'s critical path and ~91% of `noabs`'s. Adding registers does not
  shorten wires: `noabs` traded 1.8 ns of logic for 2.2 ns of routing and lost.
* **Something must break the recirculation path** from the last round back to
  `state[0]`, and there are two ways to get one, which compose: a fabric flop
  (placeable, so it is its own relay) or `extra_delay` pass-through stages.
  With neither, the path terminates at `state[0]` on every seed.
* Measured clock-to-Q: fabric flop **0.1 ns**, BRAM output register
  (`DOA_REG=1`) **0.9 ns**, unregistered BRAM **2.1 ns**. A fabric register
  beats the BRAM's own output register, which is why `BRAM_OUTREG=0` wins.

## Known remaining ceiling

The critical path now runs `crypt.state[0]` -> **pre-mix** -> `crypt.state[1]`:
a 10-way 64-bit XOR reduction feeding all 640 output bits, combinational, in
one clock. ~6.4 ns, so it caps this design near 156 MHz on a typical seed.
Pipelining it is straightforward (register `total`, delay `in` one cycle) and
costs no throughput, but was deliberately not done — the target is met with
margin and `encrypt.v` regenerates every 10 days.

## Re-baselined onto current RTL — 2026-08-30

The `cb224b6` pin was lifted once the display work and the six touch/LCD
defects from the code review had landed (`afa4b22`) and the tree was clean.
Same configuration, re-measured on the new sources:

| RTL baseline | n | median | pass ≥133.33 | all |
|---|---|---|---|---|
| `cb224b6` (pre-display) | 5 | 166.81 | **5/5** | 149.28 154.56 166.81 177.94 180.47 |
| **`afa4b22`** (with display) | 5 | **155.79** | **5/5** | 145.14 152.44 155.79 174.98 197.43 |

**Still 5/5 passing**, worst case 145.14 — 9% margin. The display path costs
~11 MHz of median, which is the expected price of added logic, and the spread
widens (145–197 against 149–180).

Note the two runs were initially recorded under one tag, producing a
meaningless n=10 median belonging to neither baseline. `run_e2nb_fixed.sh` now
tags by `RTL_PINNED_COMMIT` so datasets from different sources cannot merge
silently.
