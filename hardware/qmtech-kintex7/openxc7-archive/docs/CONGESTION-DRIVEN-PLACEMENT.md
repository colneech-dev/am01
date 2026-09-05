# Making the HeAP placer congestion-driven

Design note. Nothing here is implemented beyond patch 0006, which is a partial
first step and is off by default.

> **SUPERSEDED IN PART, 2026-08-23.** The "Level 2" recommendation below — folding
> congestion into HeAP's bound2bound solve — was independently advised against by
> two investigations (VPR/VTR and nextpnr-upstream). HeAP minimises a quadratic
> system, so there is no cost delta to add a term to, and VPR's own analytic flow
> handles density in the **legaliser**. Spindler's move force (DATE'07 Eq. 8) is
> algebraically the same object as HeAP's existing alpha anchor at
> `placer_heap.cc:961`, so a congestion term belongs as a **second anchor**, not
> inside the objective. See `CONGESTION-RESEARCH-PLAN.md` §1.3 and §3 Step 4.
>
> Also note: VPR's ablation puts congestion-aware placement at **0.979× critical
> path** — it buys routability and runtime, not Fmax.

## The problem

`common/placer_heap.cc` minimises **wirelength subject to BEL capacity**. It has
no model of routing demand at all. Counting mentions:

| file | "congestion" terms |
|---|---|
| `common/placer_heap.cc` | 4 — **all comments** |
| `common/router2.cc` | 22 — real |

There is even a comment at `placer_heap.cc:1256` referring to "what
congestion-aware placers model".

The spreader only reacts to strict tile overflow:

```cpp
// CutSpreader::find_overused_regions()
if (occ_at(x, y, t) > bels_at(x, y, t)) { overutilised = true; break; }
```

On this design that never fires, because BEL utilisation is 9%:

```
SLICE_LUTX   40710 / 407600    9%
SLICE_FFX    27607 / 407600    6%
RAMB18E1       420 /    890   47%
```

So the placer is free to concentrate logic arbitrarily: nothing it measures
objects, and the cost only appears at routing.

### Why this matters more than it sounds

**Placement metrics stop predicting routability.** Wirelength and the
post-placement timing estimate measure what the placer optimises, which is not
what limits this design. Measured: confining each pipeline stage's logic to a
band around its own BRAMs *improved* both metrics — post-place 121.88 MHz against
97.47 — and made the design unroutable.

```
iter | unconstrained | region-constrained
  12 |          39   |    695
  17 |           4   |    638
  22 |           0   |    548   (still falling ~15/iter, oscillating)
```

Three separate region runs, none converged, against a baseline that reached zero
overuse in 22 iterations.

`floorplan_stripe.py`'s own header records the same effect from an earlier
experiment: the N=1 block floorplan had the best wirelength of anything tried and
routing collapsed, because ~200 BRAM outputs leaving one 10-tile region saturate
local egress.

**Rule of thumb this produces: never accept a placement improvement measured only
post-placement. Route it.**

## What patch 0006 does, and does not

`NEXTPNR_WIRE_DEMAND=<cap>` adds a RUDY estimate (each net spreads its
half-perimeter uniformly over its bounding box) as a **second overflow condition**
in `find_overused_regions()`, reusing the spreader's existing region-growth and
redistribution machinery.

That makes the placer *react* to congestion. It does **not** make it
congestion-**driven**: the estimate never enters the objective, so the solver
still has no reason to avoid congestion when choosing where cells go. It is a
correction applied after the solve, not a term the solve minimises.

Status: unmeasured, off by default.

## Three levels, increasing in cost

### 1. Weighted spreading (nearly free)

Today a tile is congested or not — binary. Instead let the spreader's target
*density* fall where demand is high: spread harder in congested areas, leave
sparse ones alone. A small change to the existing region logic.

Still reactive, but strictly better than the binary trigger, and cheap.

### 2. Congestion in the bound2bound weights — the real answer

HeAP builds a linear system in which each net contributes

```
weight = 1 / (users × distance)
```

Add a term so that nets crossing congested tiles are pulled shorter — or
equivalently, inflate the *effective distance* through congested regions so the
solver routes around them. That makes congestion part of what the solve
minimises, which is what "congestion-driven" actually means.

Requirements:

* the demand map must be available inside `build_equations()`;
* it must be **iterative**: solve → measure demand → reweight → re-solve, exactly
  as the router negotiates congestion.

That is the standard formulation, and it is how commercial placers do it. The
iteration structure already exists — HeAP loops with increasing `alpha`, so
demand can be recomputed on the same cadence rather than needing a new loop.

### 3. Timing × congestion coupling

The critical path is a *specific* net. Congestion only matters where it
intersects critical paths, so weighting by `crit × demand` targets effort where
it changes Fmax, rather than smoothing demand globally.

Most valuable, most invasive, and only worth attempting once 2 is working and
measured.

## Recommendation

**Level 2, iteratively, gated off by default.**

It is the smallest change that makes the placer genuinely congestion-driven, it
reuses the existing linear system rather than adding a parallel mechanism, and
the iteration structure is already there.

## Caution

Adding a term to the solve changes **every** placement, not only congested ones.

Given the pattern established repeatedly on this design — plausible placement
changes that improved placement metrics and routed worse — this should be:

* off by default until measured;
* judged **only** on routed Fmax, never on wirelength or the post-place estimate;
* measured against a reproducible baseline with a known seed spread, because
  seed-to-seed variation on this design is around 20% at matched iterations, and
  a single run cannot distinguish a real effect from that.

## Why the obvious alternatives are not the answer

| idea | why not |
|---|---|
| tune `beta` | only governs how far an *already overflowing* region grows; with ~no overflow at 9% utilisation it has nothing to act on |
| tune the spreader's trigger threshold | the trigger is the right place for patch 0006, but a threshold cannot express *where* to move cells |
| region/floorplan constraints | measured three times; concentrates demand and routes worse |
| stronger router congestion pricing | tried (`NEXTPNR_CONG_GROWTH`); markedly worse early. The router already prices congestion — it cannot undo a placement that put the demand there |

## References

* `common/placer_heap.cc` — `find_overused_regions()`, `build_equations()`,
  `CutSpreader`
* `common/router2.cc` — for contrast, a working negotiated-congestion loop
* `patches/0006-nextpnr-heap-wire-demand-spreading.patch`
* `patches/0007-nextpnr-arch-isglobalnet-api.patch` — global nets must be excluded
  from any demand estimate; they use dedicated routing and their bounding boxes
  span the die
* `README.md` — "The placer has no congestion model"
* YosysHQ/nextpnr#1784 — filed, covering the region-constraint usability side
