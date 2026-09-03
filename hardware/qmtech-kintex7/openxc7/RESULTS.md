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

## Two miners: balanced-partition floorplan reaches 3034 residual overuse, then hard-fails -- 2026-08-31

Motivation: hashrate scales as `NUM_MINERS x Fmax`, so two miners beats one
even at a clock that fails the 133.33 MHz target (2 miners @ 100 MHz = 1.28x
one miner @ 155.79). `am01_qmtech_top_nm2.v` is `nm1` with `NUM_MINERS(2)` and
nothing else, so the comparison attributes cleanly to miner count.

Two miners need 840/890 BRAM sites (94% occupancy), so the y-base-40 floorplan
trick that was worth +29 MHz for one miner is unavailable -- there is no free
half of the device left. `floorplan_brams.py --mode compact` partitions sites
BY BUDGET rather than by whole column, giving each miner ~445 sites (6% slack)
with column 3 shared at a row boundary, replacing an earlier whole-column
split that gave miner 0 zero slack and miner 1 the short column (col 6 ends at
Y59) -- that version stalled at overuse 56617 (iter 1-4: 332512 -> 110321 ->
70128 -> 56617, reduction ratio collapsing 3.01x -> 1.57x -> 1.24x).

The balanced partition is a large, real improvement over that -- but still
does not converge:

| seed | iter=1 overuse | outcome |
|---|---|---|
| 1 | 307999 | ground down to 3034 by iter=31 (~15h), then **hard router failure**: `ERROR: Failed to route arc 174 of net odocrypt_gpio_wrapper_inst.g_miner[1]...midread, from SITEWIRE/SLICE_X88Y222/DQ to SITEWIRE/SLICE_X89Y220/C3` |
| 3 | 320092 | tracked seed 1's trajectory closely at every matched iteration (e.g. iter=11: 5608 vs seed 1's 5330); killed intentionally at iter=16 (overuse=3878, no error yet) to free RAM for the congestion-aware experiment below, which had become the higher-value run |

Seed 1's failure is not a slow-convergence timeout -- router2 exhausted its
search budget on one specific arc near the miner-1 boundary and aborted the
whole run. After 31 iterations of steady (if noisy and decelerating)
improvement, the last handful of contested arcs proved genuinely unroutable
within budget, not merely slow to resolve.

`--placer-heap-beta` was tested both directions (0.5, 1.4) against default
(0.9), compared at iter=1: 373111 and 439092 respectively, both worse than
default's 307999. Beta is not a lever here -- see
`am01-placement-hotspot-findings` memory for the mechanism (it only
redistributes the unconstrained LUT/FF logic around the BEL-pinned BRAMs; at
94% occupancy there's no free area for that redistribution to drain
congestion into).

**Working conclusion (superseded below):** 94% BRAM occupancy does not route
to completion in this flow (yosys/nextpnr-xilinx/prjxray) on this device
within a practical time budget, with a plain floorplan and no congestion
awareness in placement. This was consistent with the placer/router having no
congestion-aware placement step (see `am01-general-floorplanner-idea`
memory) -- Vivado handles the same BRAM density because it spreads logic away
from saturated columns *during* placement rather than discovering the jam
during routing and fighting it with rip-up/reroute after the fact.

## Congestion-aware placement: ~30x lower residual overuse, still does not fully route -- 2026-08-31

`nextpnr-xilinx-heatmap` commit `42cecc26` (2026-08-23) already implements
the missing congestion-aware placement step, gated behind env vars, unused
and "unmeasured on any real design" until now:

* `NEXTPNR_TILE_NETS=<w>` -- during strict legalisation, charges a cell for
  each of its input nets that is not already entering the destination tile
  (shared-driver cells are free; a genuinely new source costs `w`). Targets
  the verified geometric-median hotspot mechanism directly (see
  `am01-placement-hotspot-findings` memory).
* `NEXTPNR_WIRE_DEMAND=<cap>` -- a RUDY estimate (each net spreads its
  half-perimeter uniformly across its bounding box) feeding HeAP's spreader,
  which is otherwise blind to routing demand on a design this lightly
  occupied in LUTs/FFs.

Tested together (`TILE_NETS=8 WIRE_DEMAND=5.0`) on the same balanced
2-miner floorplan, seed 5:

| iter | plain floorplan (seed 1/3) | congestion-aware |
|---|---|---|
| 1 | 307999 / 320092 | 301961 |
| 2 | 45858 / 49770 | 39540 |
| 11 | 5330 / 5608 | 687 |
| 29 | (seed1 hadn't reached this low) | 262 |

At matched iterations the congestion-aware run ran at roughly **8x lower
overuse than the plain floorplan by iter=11**, and kept dropping to a floor
around **96-140** by iter~76-108 -- a **~30x lower residual** than seed 1's
terminal 3034.

**FINAL for this attempt (2026-09-01):** it did not reach overuse=0. Best
overuse was **96 at iter=76**, never beaten again; overuse then drifted
upward (145 by iter=129, 219 by iter=164) rather than settling flat, so this
was a genuine floor, not noise around a slow decline. Killed at iter=164 as
no longer productive (~13h runtime). No stall-out or hard router error was
reached -- it was still slowly getting worse when stopped, well before
`NEXTPNR_ROUTER2_MAX_STALL=250` would have force-terminated it (~iter 326).

**Revised conclusion:** placement-time congestion awareness is a real,
large lever on this design -- not a marginal tweak. `TILE_NETS` and
`WIRE_DEMAND` should be considered required, not optional, for any further
94%-occupancy attempt, but this configuration alone (8, 5.0) is not
sufficient to fully route.

## Ground-truth congestion feedback -- phase 1 result, phase 2 launched -- 2026-09-01

`run_2miner_congmap.sh`: the same `TILE_NETS=8 WIRE_DEMAND=5.0` placement,
seed 5, forced through to completion via
`NEXTPNR_SKIP_FAILED_ARCS=1 NEXTPNR_DUMP_CONGESTION=<path>` instead of
hard-erroring on the first unroutable arc. Ran ~15h (574 iterations). The
run was not monotonic -- it broke through its earlier plateau mid-way
(new best: overused=59, unrouted=2 at iter=324, later briefly overused=61
unrouted=0 at iter=385) before degrading again into a worse oscillation
(peaked overused=258). Final accepted state at iter=574 (stall-out):

    router2: SKIP_FAILED_ARCS - accepting partial route with 188 overused
    wire(s) after 574 iterations; 319 net(s) left with unrouted arcs.

Not a working design (319 unrouted nets is substantial), and the `clk_h`
timing line reported was unchanged from the pre-route estimate (nextpnr
can't compute real post-route delay through that many unrouted nets) --
not a genuine result either way. But it exported
`seedrun/2miner_congmap_s5_tn8_wd5.0/congestion.csv` (365 rows, 188KB): the
REAL per-tile overuse this specific placement produced, not a proxy.

**Phase 2** (`run_2miner_congmap2.sh`, launched immediately after, seed 7):
same `TILE_NETS=8 WIRE_DEMAND=5.0` base plus
`NEXTPNR_CONGESTION_MAP=<phase-1 congestion.csv> NEXTPNR_CONGESTION_W=2`
(first-guess weight, not tuned) -- confirmed loading
(`NEXTPNR_CONGESTION_MAP: loaded 365 rows`) and actively legalising against
it. This is the design's first attempt guided by measured routing failure
rather than a placement-time guess. Check the live log / a later update for
the outcome.

**If this does not fully route either:** retune `TILE_NETS`/`WIRE_DEMAND`
magnitudes directly (e.g. `TILE_NETS=16` or `24`) as a cheaper, less
targeted next bet, or fall back to BRAM->LUT conversion (see
`am01-hashrate-scaling-options` memory) to reduce occupancy below whatever
level this flow can actually route.

**`CONGESTION_W=2` result (2026-09-01): killed at iter=10, consistently
worse than the plain congestion-aware baseline (no map) at every matched
iteration** -- iter=1: 305287 vs 301961, iter=3: 14003 vs 7021, iter=9: 5989
vs 824, iter=10: 5847 vs 727 (baseline numbers). The gap widened rather than
closed as iterations progressed.

**`CONGESTION_W=0.5` result: also killed, also underperforming** -- iter=3:
17948 (vs baseline 7021, vs cw=2's 14003 -- WORSE than both), iter=5: 11464
(vs baseline 1761). Confounded by seed variance (seed 8 vs 7 vs 5), but
across both weights tried, the ground-truth `CONGESTION_MAP` never beat the
plain `TILE_NETS`/`WIRE_DEMAND` baseline at any matched iteration. Killed at
iter=7 (overuse=10148) to redirect effort.

## Discovered pre-existing research -- reframes the whole approach (2026-09-01)

Found `CONGESTION-RESEARCH-PLAN.md`, `SESSIONS.md`, `TESTS-TO-RUN.md`, and
`AUDIT-BUILT-VS-TESTED.md` in this same directory, dated 2026-08-22 through
08-28 -- extensive prior work on these exact same placer knobs
(`TILE_NETS`/`WIRE_DEMAND`/`CONGESTION_MAP`), not previously read this
session. Key facts that change confidence in tonight's approach:

* **`TESTS-TO-RUN.md` T16 confirms tonight is the first real 2-miner routing
  attempt** -- "openXC7 has only ever built `nm1`." Not duplicated work.
* **`SESSIONS.md` already flagged the exact regime tonight is fighting**:
  "`NUM_MINERS=2` needs 840/890 BRAMs = 94% utilisation. Vivado does it; the
  striping strategy has almost no room to distribute egress at that
  density." Written before tonight, independently arrives at the same
  conclusion reached the hard way over ~30h of nextpnr runs.
* **`WIRE_DEMAND=5.0` (used all night) was never grounded.** The 1-miner
  placer-knob screen in `AUDIT-BUILT-VS-TESTED.md` sec 2a found `WIRE_DEMAND`
  has a real, non-monotonic optimum near **1.0** (2.0 too loose to trip any
  tile, 0.5 tight enough to thin the whole die). Different regime (1-miner
  Fmax vs 2-miner routability), so not guaranteed to transfer, but a far
  better-grounded value than the blind guess used tonight.
* **The single most decisive untried experiment is a 2-miner version of T5**
  (Vivado's placement fed into nextpnr's own router). The 1-miner equivalent
  already ran (`CONGESTION-RESEARCH-PLAN.md` "Step 1") and established
  *"placement owns the gap, not routing"* -- nextpnr's own router beat
  Vivado's router (89.30 vs 63.55 MHz) on the *same* nextpnr placement. That
  result validates attacking placement rather than the router -- but only
  for the 1-miner Fmax problem; nobody has run the 2-miner routability
  version. Would need the existing `vivado_route_nextpnr_placement.tcl`
  name-mapping pipeline extended to the 2-miner netlist. Bigger undertaking
  than a parameter sweep; flagged as the real next investment, not
  attempted tonight.

**`TILE_NETS=8 WIRE_DEMAND=1.0` (seed 9) result: also killed, also
underperforming** -- iter=1: 349740 (vs wd=5.0's 301961 -- WORSE), iter=3:
27125 (vs 7021). The 1-miner-screened "optimum" of 1.0 does not transfer to
this regime either. Across every weight/map combination tried tonight
(`WIRE_DEMAND` 1.0/5.0, `CONGESTION_W` 0.5/2, with and without
`CONGESTION_MAP`), the plain `TILE_NETS=8 WIRE_DEMAND=5.0` configuration
(seed 5, best combined overuse 61 at iter=324) remains the best result
found. Killed at iter=3 to redirect effort toward Option A (below), which
sidesteps the BRAM-occupancy wall directly instead of continuing to search
this parameter space.

---

# Option A / Option B: escape the BRAM wall instead of fighting it (2026-09-01)

Every 2-miner attempt above fights the same 94% BRAM occupancy wall through
placement/routing tricks. Two alternatives instead **reduce the resource
demand directly** -- sized and one of them (A) launched tonight; the other
(B) is planned, not executed, for pickup later. Both build on the "known
good" recipe throughout this project: `odo_gen --bram-out-reg`,
`BRAM_OUTREG=0` (register in fabric), `BRAM_FP=1 BRAM_YBASE=40` (starting
point -- see caveat below), `CRIT_DIST=1.0` (build.sh default).

## THROUGHPUT is discretized, not a dial

`odo_gen`'s `THROUGHPUT` argument is literally clocks-per-hash, an integer.
Internally `unrolling = (ROUNDS-1)/throughput + 1` (`ROUNDS=84`), and the
*real* measured throughput is `periods = (ROUNDS-1)/unrolling + 1` --
integer division, so hashrate only changes at specific `unrolling`
thresholds. Checked exhaustively: `unrolling=21..27` all give `periods=4`
(today's baseline, 1.00x), `unrolling=28..41` all give `periods=3` (1.33x,
no better with more area), `unrolling=42` gives `periods=2` (2.00x). There
is no resource-efficient point between these -- "THROUGHPUT=3.5" is not
buildable; 28 is already the minimum-area point for 1.33x.

BRAM per unrolled round, measured from the existing 1-miner design: exactly
**20** (420 BRAM / unrolling=21). Scales linearly with unrolling.

| `THROUGHPUT` | unrolling | BRAM | occupancy | hashrate (same Fmax) |
|---|---|---|---|---|
| 4 (current 1-miner) | 21 | 420 | 47% | 1.00x |
| 3 | 28 | 560 | 63% | 1.33x |
| 2 | 42 | 840 | 94% | 2.00x -- **same wall as 2 miners** |
| 1 | 84 | 1680 | 189% | doesn't fit |

`THROUGHPUT=2` alone is not an escape from the wall -- it's the *same*
840/890 occupancy as `NUM_MINERS=2`, reached via one 42-stage pipeline
instead of two 21-stage ones. Not obviously better (arguably worse: one
long serial chain instead of two chains that can each occupy their own half
of the die), and not attempted for that reason.

## LUTRAM conversion: the direct fix for BRAM occupancy

LUT occupancy is nowhere near its ceiling at any config tried (~10-21%
typical). Xilinx SLICEM LUTs can implement small RAMs (`ram_style =
"distributed"`) instead of block RAM (`"block"`) -- a per-module synthesis
attribute, no schedule/latency change. 10 distinct large-sbox module types
exist (`STATE_SIZE = DIGEST_BITS/WORD_BITS = 640/64 = 10`), each
instantiated once per unrolled round, so converting N of 10 gives almost
exactly N/10 of BRAM demand moved to LUT fabric. Cost model (measured
elsewhere, see `am01-hashrate-scaling-options` memory): ~420 LUTs per
converted instance.

## Option A (LAUNCHED 2026-09-01): `THROUGHPUT=2` + `--lutram=3`

Converts 3 of 10 sbox types to LUTRAM, bringing `THROUGHPUT=2`'s BRAM
demand from the 94% wall down to the same 63% that `THROUGHPUT=3` reaches
unaided -- while keeping the full 2.00x hashrate:

| | BRAM | LUT | hashrate |
|---|---|---|---|
| computed | 560 (63%) | ~208k (51%, **never tested on this design**) | 2.00x |

**Implementation, done tonight:**
* `odo_gen` gained `--lutram=N`: marks the first N of the 10 large-sbox
  module types `ram_style="distributed"` instead of `"block"`.
* `hdl/odocrypt/miner_t2.v`: `THROUGHPUT=2` variant of the pinned `miner.v`
  (THROUGHPUT and the encrypt module name are compiled-in, not
  parameterised -- a separate file was cheaper and safer than making
  miner.v itself parametric). Must never be compiled alongside `miner.v`
  (duplicate module names -- fails loudly, not silently).
* `run_option_a.sh`: the known-good build recipe with `miner.v` swapped for
  `miner_t2.v` and the wider `--lutram=3` core. Asserts key taps (**1 4 7**,
  unchanged -- `RoundKeyTap` depends on `RoundCycles()`, i.e.
  `--bram-out-reg`, not on throughput) and the lutram split (3
  distributed / 7 block) before spending hours on synthesis.
* Functional equivalence (`--lutram=3` vs `--lutram=0`, both `THROUGHPUT=2`,
  same schedule/latency -- verified identical at 254 cycles by inspecting
  the generated RTL) is running via `run_lutram_equiv.sh` /
  `tb_lutram_equiv.v`, same queue-compare + negative-control methodology as
  `run_sched_equiv.sh`. **Check its verdict (`sched_pos.out`/`sched_neg.out`
  equivalent: `lutram_pos.out`/`lutram_neg.out` in `/tmp`) before trusting
  any Option A result** -- a `--lutram` bug would produce a fast-looking
  netlist with wrong digests, the exact failure mode `RoundKeyTap` already
  demonstrated once this session.
* Synthesis launched (`run_option_a.sh`, tag `optionA_t2_lutram3`, out dir
  `out_option_a/`). Check `option_a.console` and `seed_ab_results.tsv` for
  the outcome.

**Real, unproven risk:** 51% LUT occupancy is a new regime for this design
-- everything measured so far tops out around 21-25%. `BRAM_YBASE=40` is
carried over from the 420-BRAM 1-miner layout; this design needs 560, so it
may spill past Y139 and need retuning -- watch the floorplan report for
spills before trusting the routed number.

## Option A synthesis FAILED -- `ram_style="distributed"` cannot map a pure ROM on this yosys (2026-09-02)

**The build ran for ~12 hours** (started 22:16, crashed 05:35) under severe
memory pressure -- yosys peaked at ~11.3 GB RSS / 20+ GB VSZ on a WSL box
with an 11 GB RAM allocation, driving swap to ~13 GB and stalling the whole
WSL VM unresponsive to new commands at least twice. It eventually failed at
`MEMORY_LIBMAP`, not from resource exhaustion:

    found attribute 'ram_style = distributed' on memory
    ...round40.sboxes.sbox17inst.mem, forced mapping to distributed RAM
    ERROR: no valid mapping found for memory
    ...round40.sboxes.sbox17inst.mem

**Root cause, confirmed with isolated <1-minute tests** (not the 12h full
build) once the failure was understood:
`techlibs/xilinx/lutrams_xcv.txt` -- the LUTRAM mapping rules this yosys
build uses for `xc7` -- require every candidate memory to have **at least
one write-capable port** (`port arsw "RW"`). The large-sbox tables are
genuine ROMs: written only in an `initial` block, never at runtime, zero
write ports by construction. Four workarounds tried, all fail the same way
or worse:

| approach | result |
|---|---|
| `ram_style="distributed"` (what Option A shipped) | `ERROR: no valid mapping found` -- reproduces the 12h crash in <15s isolated |
| + a dummy write port, permanently disabled | Same error -- likely const-folded away before `memory_libmap` runs |
| `ram_style="logic"` | **Silently drops the memory's read logic entirely** (only FDRE/IO cells in `stat`, no LUTs, no BRAM) -- a correctness bug, not a fix; never trust this value |
| `case`-statement ROM, no array, clocked or purely combinational + separate register | Yosys's own `proc`/memory-inference still recognises the pattern and reinstates `RAMB18E1` regardless of coding style |

**What survives:** the RTL mechanism itself is confirmed correct at the
simulation level -- `run_lutram_equiv.sh` finished with the ideal verdict
(`positive: PASS -- 32 results identical`, `negative: FAIL -- 30 of 32
differ`, `=> SOUND`). `--lutram=N`'s Verilog output is byte-for-byte
behaviour-neutral; the failure is purely a synthesis-tool limitation
(`memory_libmap`'s LUTRAM rules), not a bug in `odo_gen` or in the
generated RTL. If a working LUT-ROM technique is found later, the
`--lutram=N` flag and `miner_t2.v` do not need to change.

**What a real fix would need:** bypassing `memory_libmap` entirely for
these tables -- most likely hand-building the address-decode mux tree from
explicit LUT6 primitives via a `generate` block (the technique Vivado's
`phys_opt_design`/XST use for ROM-shaped LUTRAM, and reportedly what some
open designs do with an explicit `\$lut` instantiation per output bit
group), rather than relying on any `ram_style` value. Substantially bigger
and riskier than the attribute change tried here. **Not attempted --
flagged for whoever picks this up next.**

**Process/infrastructure lesson, independent of the RTL/synthesis
question:** this WSL box needs either a larger memory allocation
(`.wslconfig` `memory=` setting) or a smaller synthesis job before
attempting a design this size again -- 11 GB was not enough headroom even
for a build that would have succeeded on the RTL/logic side, and the
resulting swap-thrash made WSL itself unresponsive for extended stretches,
independent of whether the LUTRAM mapping issue existed.

## `THROUGHPUT=3` alone (no LUTRAM): WORKS, but timing is marginal -- 2026-09-02

The one member of this family that sidesteps the broken LUTRAM mechanism
entirely: no `--lutram`, all 10 large-sbox types stay `ram_style=block`.
**This is the first fully successful alternative build of the whole
session** -- routes cleanly, unlike every 2-miner attempt and unlike Option
A's crash.

**Resource counts, confirmed exactly as sized:**

| | measured | sized estimate |
|---|---|---|
| BRAM | **560 (62.9%)** | 560 (63%) -- exact |
| LUT | **47,565 (11.7%)** | ~56k (14%) -- came in lower |

**Synthesis and routing both comfortable.** Unlike Option A's 12h crisis,
this design (only 1.33x baseline vs Option A's ~5x scale) synthesised in a
few hours without a memory crisis, and every seed routed cleanly to
`overuse=0 unrouted=0` in 8-19 iterations -- no congestion fight at all,
consistent with 63% BRAM being comfortably inside the routable regime this
whole session's 2-miner work never found for 90%+ occupancy.

**But timing is marginal and seed-dependent, unlike the 1-miner baseline:**

| source | clk_h | vs 133.33 MHz |
|---|---|---|
| `build.sh`'s own unseeded route | 141.74 | PASS |
| seed 1 | 132.71 | **FAIL** (by 0.6 MHz) |
| seed 2 | 121.95 | **FAIL** |
| seed 3 | 143.88 | PASS |

**Median (n=3): 132.71 MHz -- technically fails the target.** Relative
hashrate at median: **1.14x** (vs the 1.33x ceiling and vs 2.00x for
`THROUGHPUT=2`, which remains blocked on the LUTRAM issue). Two of four
measured configurations fail outright. Contrast with the 1-miner baseline,
where the *worst* of 5 seeds (145.14) still clears target with 9% margin --
every seed there passes. A design that only sometimes meets timing is not a
reliable win.

**Not a floorplan-overflow bug** -- checked the floorplan report directly:
all 28 rounds fit cleanly within Y40-139 (round 27 ends exactly at Y139,
no spill).

### y-base sweep (2026-09-02): 40 is already the best of what's testable in this geometry

Reused the already-synthesised netlist (`BRAM_YBASE` only affects the
floorplan step, not synthesis) to sweep candidates without a
resynthesis -- `run_throughput3_ybase_sweep.sh`. Result: **nothing beats
the original 40.**

| y-base | seed 1 result | note |
|---|---|---|
| 0 | 107.70 MHz | **invalid** -- killed mid-route (68+ min stuck on iter=1, then slow iter=2; consistent with the historical finding that y-base=0 was the worst option for the smaller 420-BRAM case too) |
| 20 | **118.41 MHz** | genuine, converged cleanly (iter=103, `overuse=0`) -- but worse than 40 |
| **40** | **132.71 MHz** | unchanged from the original build -- remains the best found |
| 53 | -- | **floorplan generation failed outright**: Y53-137 is 84 rows x 6 cols = 504 slots, doesn't fit 560 BRAM |

So the marginal, seed-dependent timing at y-base=40 is not an easy
misconfiguration -- it looks close to the actual ceiling for this specific
**6-column** floorplan geometry (`--columns 0,1,2,3,4,5`, hardcoded in
`build.sh`, also carried over unchanged from the 1-miner default) at 560
BRAM.

### Column-count fix (2026-09-02): adding X6 WORKS -- 134.86 MHz, real PASS

Column count, not row range, was the right lever. Reused the synthesised
netlist again, this time varying `--columns` instead of `--y-base`
(`run_throughput3_cols7.sh`). `--columns 0,1,2,3,4,5,6` (adding X6, which
only contributes ~20 rows at y-base=40 since it stops at Y59 -- not a full
7th column, just extra room where the floorplanner needs it):

| config | seed 1 | vs 133.33 MHz |
|---|---|---|
| 6 columns, y-base=40 (original) | 132.71 MHz | FAIL (by 0.6 MHz) |
| **7 columns (+X6), y-base=40** | **134.86 MHz** | **PASS** (1.53 MHz / ~1.1% margin) |

Confirmed as the genuine post-route result (line order checked directly:
the reported `Max frequency` follows `iter=49 ... overuse=0`, not a
pre-route estimate). Seeds 2-3 launched to confirm this isn't a lucky
single seed before adopting it as the new default. **This is the first
real, confirmed improvement found for THROUGHPUT=3's marginal timing.**

### `rom_style` lead investigated and ruled out for yosys (2026-09-02)

A parallel effort (memory: `am01-hashrate-scaling-options`, "MEASURED
2026-09-02: --lutram=3 with 3 miners") building the same `--lutram`
mechanism via **Vivado**, targeting `NUM_MINERS=3`, found Vivado silently
falls back to raw combinational logic (~730 LUT/instance, not the ~420
this project's cost model assumed) rather than hard-erroring like yosys
does, and suspected `rom_style` (not `ram_style`) is the attribute Vivado
actually needs for a write-less memory -- untested there as of that
writing.

**Tested on yosys, cheaply (isolated <1min test, not a full rebuild):
`rom_style="distributed"` hits the identical `ERROR: no valid mapping
found` as `ram_style`.** yosys's `MEMORY_LIBMAP` recognises the attribute
name (`found attribute 'rom_style = distributed'...`) but applies the same
write-port-required LUTRAM rule regardless of which attribute signals ROM
intent. **Does not unblock Option A / `THROUGHPUT=2` on this toolchain.**
Worth trying on the actual Vivado flow if that effort continues -- the two
toolchains' `memory_libmap`/synthesis behaviour are unrelated, so a Vivado
result doesn't transfer either direction.

**Coordination note:** that same session left a comment in the memory file
flagging `odo_gen.cpp`'s `--lutram` mechanism as uncommitted/not-theirs and
asking to check with whoever wrote it -- that's this work (committed on
`claude/option-a-wide-miner-lutram`, not yet merged anywhere they'd see it
by default). Worth a heads-up to avoid duplicate or conflicting `--lutram`
implementations landing independently.

**Config used:** `odo_gen <epoch> 3 encrypt_3 --bram-out-reg` (no
`--lutram`), `miner_t3.v` (THROUGHPUT=3 variant of the pinned miner.v),
`BRAM_OUTREG=0 BRAM_FP=1 BRAM_YBASE=40 CRIT_DIST=1.0` (build.sh defaults,
unchanged from the 1-miner recipe), `--columns 0,1,2,3,4,5,6` (fixed from
build.sh's hardcoded 6-column default via `run_throughput3_cols7.sh`).
Results in `seed_ab_results.tsv`, tags `throughput3` (original 6-col) and
`throughput3_cols7_yb40` (the fix).

### Seed 3 does NOT converge without congestion awareness (2026-09-03)

Completing the 7-column seed set honestly: seed 3 **failed to route** --
600 router iterations, `overuse=82` residual, never reached 0. Its
`129.20` row in `seed_ab_results.tsv` is therefore **not a routed result**;
with overuse != 0 that figure is the stale pre-route SA estimate. Read
correctly the set is **2 of 3 seeds pass, 1 of 3 fails to route at all** --
so THROUGHPUT=3's real defect is convergence variance, not median Fmax.

## Congestion-aware placement: measured, and it fixes the failing seed (2026-09-03)

Implemented real congestion awareness in the HeAP placer (branch
`congestion-aware-placement` in the nextpnr tree, commits `e317869a` and
`ec7d4066`): a per-tile routing-capacity map built from `ctx->getWires()`
using the same wire-location rule as `router2::setup_wires()`, congestion
expressed as demand/capacity (`NEXTPNR_CONG_RATIO`), and congestion
allowed to STEER the spreader -- tightening the region density target and
weighting the cut objective (`NEXTPNR_CONG_SPREAD`) -- rather than merely
triggering it. Both knobs default off and multiply by exactly 1.0 when
off; verified bit-identical against the old binary over 4 placement
iterations on an identical netlist and seed.

**Two wrong hypotheses, both caught by measurement rather than reasoning,
recorded because the reasoning looked sound each time:**

1. *"`build_wire_demand()` is computed once and never refreshed."* Wrong --
   `CutSpreader` is constructed per HeAP iteration, so the demand map
   already tracked the placement. Only the capacity denominator was absent.
2. *"RUDY demand must systematically exceed wire-count capacity (a units
   mismatch)."* Wrong. Instrumenting it (`NEXTPNR_CONG_STATS=1`) over 78302
   wired tiles gave capacity p50 249.0, demand p50 0.84, **ratio p50
   0.016**, with only 7-17% of tiles above 1.0. Units are broadly sane.
   The real defect was **aggregation**: `cong_max()` took the MAXIMUM over
   a region against a distribution whose max is 1310, so one degenerate
   tile (capacity p10 is a single wire) set an entire region's multiplier,
   `overused()` could never be satisfied, and regions expanded until the
   whole die was spread. Fixed by flooring the capacity denominator at
   0.25x the device median, aggregating regions by MEAN, and clamping the
   multiplier (`NEXTPNR_CONG_CLAMP`, default 2.0).

**Measured effect, same netlist and seed throughout:**

| | spread wirelen | router iters | routed `clk_h` |
|---|---|---|---|
| off (seed 1) | 5674942 | 49 | **134.86** PASS |
| broken max-aggregation (seed 1) | 13547342 (+139%) | 49 | 54.84 FAIL |
| fixed, `RATIO=1.0 SPREAD=0.5` (seed 1) | 6715551 (+18%) | **10** | 129.12 FAIL |
| off (seed 3) | -- | 600 | **never converged** (overuse 82) |
| **fixed (seed 3)** | -- | **35** | **139.66 PASS** |

**Conclusion: it buys ROUTABILITY, not Fmax -- exactly as the literature
says, and that is what this design needed.** On a seed that already routed
it cost 4.3% of Fmax and cut router iterations 49 -> 10. On the seed that
could not be routed at all it converged in 35 iterations and produced
**139.66 MHz, the best of the three**. VPR's own published ablation has the
same shape (routing failures 15 -> 1, route time 0.49x, critical path
0.979x).

So the "1 in 3 seeds fails to route" caveat above looks **fixable rather
than intrinsic**. The open question is whether to apply congestion
awareness always (costing a few percent on healthy seeds) or only as a
rescue for seeds that fail to converge -- the latter is strictly better if
the flow can retry, and needs no further tool work.

Not yet done: an in-process place -> route -> re-place loop (step 4 of the
plan). Deliberately not built -- it amplifies whatever the estimator does,
so it should only follow evidence the estimator helps, which now exists but
is a single data point.

## Option B (PLANNED, NOT EXECUTED -- pick up after Option A): two `THROUGHPUT=3` miners

Two independent `THROUGHPUT=3` wide miners (each 1.33x, 560 BRAM alone) for
a higher hashrate ceiling than Option A:

| target | BRAM | LUT | hashrate |
|---|---|---|---|
| BRAM held at Option A's 63% margin, `--lutram` on both | 560 (63%) | ~359k (**88%**, high risk) | **2.67x** |
| BRAM allowed to fill the device, `--lutram` on both | 890 (100%, no margin) | ~214k (53%) | 2.67x |

Higher ceiling than Option A (2.67x vs 2.00x) but trades BRAM congestion for
LUT congestion of similar severity (88%) at the safe-BRAM setting, or
leaves zero BRAM margin at the LUT-safe setting -- neither is as clean as
Option A's 63%/51% split. **Do not build until Option A's real routed
result is in** -- if Option A's 51% LUT occupancy turns out to already be
hard to route, Option B's 88% (or 53% LUT + 100% BRAM) is almost certainly
worse, and the sizing above should be treated as illustrative rather than a
target to build toward blindly.

**To pick this up:** it needs its own `run_option_b.sh` (two
`am01_qmtech_top`-style top levels or a `NUM_MINERS(2)`-style top wired to
two `THROUGHPUT=3 --lutram=N` cores -- N to be chosen once Option A's real
LUT-occupancy routability is known, not before), its own floorplan (two
560-BRAM regions, closer in spirit to tonight's `floorplan_brams.py`
balanced-partition work than to Option A's single-region layout), and its
own functional-equivalence run (same `tb_lutram_equiv.v` pattern, different
`THROUGHPUT`/`--lutram` values). None of that exists yet.
