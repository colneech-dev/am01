# Congestion-driven place & route: research findings and plan

Four independent investigations (RapidWright/RWRoute, VPR/VTR, nextpnr upstream,
analytical-placement literature) plus a measurement of our own congestion map.
Written 2026-08-23.

**The short version.** Three of the four investigations recommended, as their top
item, something this tree already contains. The research did not produce a new
thing to build; it produced a reason to run what is already built, and a strong
argument that congestion-driven *placement* is not where the missing 1.55× lives.

> **RESOLVED 2026-08-23 22:15 — Step 1 has run, and it selects the PLACER branch.**
>
> | place | route | clk_h |
> |---|---|---|
> | nextpnr `v68base` | nextpnr | 89.30 MHz (iter 45, 0 unrouted) |
> | nextpnr `v68base` | **Vivado** | **63.55 MHz** (0 unrouted, 0 node overlaps) |
> | Vivado | Vivado | 158.81 MHz |
>
> Vivado's router, given the *identical* nextpnr placement (68266/68450 cells
> LOC-fixed, 99.7%), came in **29% below nextpnr's own router**. The critical
> path is a flop-to-flop net with **no logic between the endpoints**:
>
> ```
> start  $auto$ff.cc:337:slice$466022/C     (flop clock pin)
> end    $auto$ff.cc:337:slice$226497/D     (flop data pin)
> logic 0.322 ns   net 15.104 ns
> ```
>
> 0.322 ns is clock-to-Q alone. Fifteen nanoseconds of pure routing to join two
> directly-wired registers is not a routing failure — the two flops are placed
> too far apart for any router to rescue, and the best commercial router
> available did worse than ours when handed the problem.
>
> **Consequence: Step 3 (the router branch) is retired.** The nine ranked
> RWRoute changes, and the untested `NEXTPNR_CRIT_WEIGHT` / `NEXTPNR_SHARE_EXP`
> knobs, all target a component this experiment exonerates. Go to Step 4.
>
> Caveat, stated rather than buried: Vivado's router was handed a fully
> constrained foreign placement, which is not the case it is tuned for. But it
> had exactly the freedom router2 had — routing only — and used it less well.
>
> Method note: the SRL cells must be excluded from the constraint set
> (`vivado_route_nextpnr_handplaced.tcl`). nextpnr packs four SRLC32E into one
> SLICEM and Vivado's LUTRAM packer refuses; pinning them harder cannot help.

---

## 1. What the research actually changed

### 1.1 The recommendations already exist here, default-off

| Recommended by | Mechanism | Status in this tree |
|---|---|---|
| RWRoute (#1) | criticality-weighted path cost | `NEXTPNR_CRIT_WEIGHT`, `router2.cc:570` — exact PathFinder blend, **default 0.0** |
| RWRoute (#4) | criticality-aware sharing factor | `NEXTPNR_SHARE_EXP`, `router2.cc:604` — exact RWRoute form read from `RWRoute.java`, **default 0.0** |
| nextpnr-upstream | spreader-side congestion feedback | `NEXTPNR_CONGESTION_MAP` / `_W`, committed in `28d98d90` |
| analytical placement (P0) | RUDY wire-demand map | `NEXTPNR_WIRE_DEMAND`, patch 0006, uncommitted |
| RWRoute (#3) | lower A\* `estimateWeight` | `router2/estimateWeight`, a `ctx->setting` — **no recompile needed** |
| RWRoute (#5) | looser vertical bounding box | `router2/bbMargin/y`, likewise a setting |

`TESTS-TO-RUN.md` already files the first two as **T7** and **T8**, under the
heading *"router knobs: built, never run"*.

The RWRoute investigation read openXC7's upstream `router2_xc7.cc`, not this
tree, so its central finding — "criticality never enters the arc's own cost" —
describes the code we forked from, not the code we run. Its diagnosis is sound
and its RWRoute source quotations are accurate; the fix is simply already
written here and switched off.

### 1.2 The effect size does not support the hypothesis

VPR's own ablation of congestion-aware placement (PR #3010, merged 2026-01-26,
**still disabled by default** — `--congestion_factor` defaults to `0.0`):

```
routing failures  15 -> 9 -> 7 -> 1     (large)
route time        0.49x                 (large)
placed wirelength +6.1%                 (worse, as expected)
critical path     0.979x                (2%)
```

Congestion-aware placement buys **routability and runtime**, not Fmax. We are
chasing 89.30 → 158.81 MHz, a factor of 1.78. A 2% mechanism cannot pay for it.

The analytical-placement investigation adds the constraint that matters most
here: every published FPGA effect size (UTPlaceF, elfPlace, RippleFPGA) comes
from ISPD'16, built specifically for routability-driven placement at 80–95%
device utilisation. **No published result exists for congestion-aware placement
below ~20% utilisation.** Our design is at 9% LUT. The mechanisms transfer; the
magnitudes do not.

### 1.3 Two independent sources contradict our own design note

`CONGESTION-DRIVEN-PLACEMENT.md` recommends "level 2" — folding congestion into
HeAP's bound2bound solve — as the real answer. Both the VPR and nextpnr
investigations advise against it, for the same reason: HeAP minimises a
quadratic system, so there is no cost delta to add a term to, and VPR's own
analytic flow handles density in the **legaliser**. Spindler's move force
(DATE'07 Eq. 8) is algebraically the same object as HeAP's existing alpha anchor
at `placer_heap.cc:961`, which means a congestion term belongs as a *second
anchor*, not inside the objective.

`CONGESTION-DRIVEN-PLACEMENT.md` should be amended to record this.

### 1.4 Spindler Fig. 3 explains a result we recorded as an anomaly

We observed that concentrating logic improved wirelength and the post-place
timing estimate but made the design harder to route. That is the published shape
of the curve, from 2007: HPWL and RSMT rise **monotonically** with routing
weight, while *routed* wirelength has a minimum at `w_rout ≈ 0.32`.

Consequence for how we measure: **HPWL and the post-place estimate are the wrong
gate.** Any congestion work will make both worse by construction, and our
existing habit of reading them will reject good solutions. This is also the
fourth time this session a post-place estimate has been misread as a routed
result.

---

## 2. Measured facts that constrain the plan

**BRAM utilisation: 420 × RAMB18E1 of 890 available = 47%.** Verified across
every netlist in `out_nm1_nosr/`. There is genuine BRAM spreading freedom — this
was the analytical-placement investigation's explicit branch point, and it lands
on the side where spreading is worth trying.

**Congestion at iteration 1 is diffuse, not a hotspot.** From
`cong_map_iter1.csv`: 22,673 of 80,808 tiles (28%) carry overuse; the worst 5%
of tiles hold only 19% of it; the worst column carries 2.6%; 137 of 222 columns
and 350 of 364 rows are affected. **This refutes the BRAM-egress-hotspot theory**
that motivated much of the floorplanning work. Caveat: this is iteration 1, so
it may measure initial demand rather than residual congestion — §3 Step 2
resolves that.

**Router defaults, verified in this tree:** `estimateWeight = 1.75`
(inadmissible A\* by construction; upstream uses 1.25), `bbMargin/x = y = 3`
(RWRoute uses x=3, **y=15**), and `curr_cong_weight += curr_cong_mult` at
`router2.cc:2302` — **additive despite the name**, giving 0.5, 2.5, 4.5… where
RWRoute is geometric 0.5, 1, 2, 4, 8.

---

## 3. The plan

Ordered so that each step can invalidate the ones after it. Nothing below Step 1
should start before Step 1 lands.

### Step 0 — free experiments, no recompile, run now

Both are `ctx->setting` values, so they need no rebuild and cost one route each.
They are independent of everything else and make later comparisons cleaner.

```
--router2/estimateWeight 1.25      (then 1.0)
--router2/bbMargin/y 12            (then 15)
```

`estimateWeight` at 1.75 guarantees suboptimal paths; 1.25 is upstream's default.
`bbMargin/y` at 3 against RWRoute's 15 is the sharper asymmetry, and a
BRAM-column design needs vertical slack to get from a RAMB18 to its consumers.

Gate: routed `clk_h`, and `overused` still reaching 0.

### Step 1 — the decisive experiment, already running

**nextpnr place → Vivado route** (`vivado_route_nextpnr_placement.tcl`, 98.71%
name match, 136,636 constraints). In flight as of 2026-08-23 09:40.

This is the only experiment that separates our placer from our router, and its
outcome selects which half of the research to act on:

- **Routes near 158 MHz** → the placement is fine, the router is the gap. Act on
  the RWRoute findings (Step 3). Stop all placement work.
- **Stays near 89 MHz** → the placement is the gap. Act on the placement
  findings (Step 4). Stop tuning router cost functions.

Its mirror, **T5** (Vivado place → nextpnr route), is still open and was
mis-recorded in `TESTS-TO-RUN.md` as done; the 158.81 MHz figure is all-Vivado.
Running both pins the gap from each side.

### Step 2 — T6, the gate that can invalidate the router branch

```
NEXTPNR_LOG_CRIT_GAP=1
```

router2 does not bind wires until `overused == 0`, so during negotiation
criticality comes from `predictDelay` — a Manhattan estimate of the *placement*.
The timing feedback loop is open.

- ratio near 1.0 → criticality is sound, and T7/T8 weight something real
- ratio 3–4× → **criticality is fiction, and T7/T8 weight noise**; closing the
  loop matters more than tuning either

This costs one instrumented run and can invalidate the RWRoute investigation's
two highest-ranked items. It found nothing about this because it is a property
of our tree, not of upstream. **Run it before T7/T8 regardless of Step 1's
outcome.**

Re-dump the congestion map at convergence in the same run, to settle whether the
diffuse pattern of §2 survives (`write_heatmap` is present; the iteration-1 call
site is `#if 0`'d).

### Step 3 — router branch, if Step 1 says router

In order, one at a time, against a fixed baseline:

1. **T7** `NEXTPNR_CRIT_WEIGHT=0.4` then `0.6`. Not 1.0: `arc_crit` clamps to
   exactly 1.0, so w=1.0 makes the most critical arcs congestion-blind.
2. **T8** `NEXTPNR_SHARE_EXP=2` (RWRoute's default), then 1 and 3. This design
   has ~7 sinks per net, so the `/(1 + source_uses)` divisor currently pays
   every later arc — including critical ones — to detour into the existing
   branch.
3. Combine, only after each is characterised alone.
4. **New, ~40 lines:** forced re-route of the top ~3% most critical arcs each
   iteration, per `RWRoute.shouldRoute()`. Today an arc that grabbed a detour in
   iteration 1 is frozen for the whole run — `route_net` skips any arc where
   `check_arc_routing()` returns true. This is the strong form of Vivado's
   `Explore` directive. Watch loop termination: router2's loop is
   `while (!failed_nets.empty())`, so forced re-routes must be capped.

Watch `overused` as closely as `clk_h` throughout. Letting critical arcs ignore
congestion is a classic way to prevent convergence.

### Step 4 — placement branch, if Step 1 says placer

1. **Instrument first.** Build the RUDY map at **device-tile granularity** and
   check it lights up where the router actually fails. Coarse binning is the
   silent failure mode — a saturated 2–3 tile region averages to nothing.
   Include the pin-density term separately (elfPlace keeps it non-accumulating
   and says why); ~200 BRAM outputs leaving one region is a pin-density
   signature, not a net-bbox one. If the estimator cannot see our problem,
   nothing downstream can help.
2. **BRAM spreading**, before touching the solve. At 47% RAMB18 utilisation
   there is room. Lower the effective `beta` for the BRAM bel bucket in
   `CutSpreader::overused()`. The `--placer-heap-beta` fix makes this a live
   knob for the first time.
3. **Thresholded congestion anchor** (~150 lines), as a *second anchor* beside
   the existing alpha term, not inside the objective. The key property is
   `if (u <= 1.0) continue;` — exactly zero outside over-capacity tiles. At 9%
   utilisation Spindler's global `w_rout ≈ 0.32` blend would just add noise to
   99% of the device. Smoothing is not optional.
4. **Snapshot-and-revert**, per OpenROAD's `revertToMinCongestion()`. Given how
   many changes here have measured worse than baseline, build this first.

**Do not build cell-area inflation.** It works only by feeding a density
penalty, and HeAP's sole consumer of density is `CutSpreader`, firing on
`cells > beta * bels`. At 9% utilisation you would need ~10× inflation to trip
it, while every tool caps inflation at 2–3× and caps total added area by
available whitespace. Those caps are calibrated for 80–95% designs; here the
mechanism they gate never engages.

---

## 4. What this plan deliberately does not do

- **Port RWRoute.** `RWRoute.SUPPORTED_SERIES` is `{UltraScale, UltraScale+,
  Versal}` — Series7 is absent, and the only timing data in the repo is
  `timing/ultrascaleplus/`. It is a source of ideas, not code.
- **Port CUFR's partitioning tree.** Pure runtime parallelism, zero Fmax effect.
- **Net-weight inflation.** No modern analytical placer relies on it; the field
  converged on move-force and area-inflation. Documented dead end.
- **Reverse-engineer Vivado's congestion levels.** A reporting construct with no
  documented feedback into the router's cost function.
- **Fold congestion into HeAP's solve** — see §1.3.

---

## 5. Open risk

The whole plan assumes nextpnr's reported net delays are real. `getWireDelay`
returns 0 on xc7 and `getPipDelay` uses a per-tile RC approximation with a
`driving_pip_loc` heuristic. If that model over-estimates long-line delay
relative to Vivado's, some part of the gap is **measurement, not routing**.

Dumping the actual PIP sequence for one failing critical arc from both tools and
comparing hop counts would settle it in about an hour, and would reorder
everything above if the two routes turn out to be similar. It is cheap enough
that it should probably run alongside Step 1.
