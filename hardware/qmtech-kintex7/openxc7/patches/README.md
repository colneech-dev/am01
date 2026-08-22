# nextpnr patches

Patches against [nextpnr](https://github.com/YosysHQ/nextpnr) (applied here to
the `nextpnr-xilinx` fork) that are candidates for upstream submission.

## Submission order

These are interdependent. Submitting only the first would let a user *express* a
floorplan that then fails to legalise, which is worse than not having it:

| patch | makes floorplans... |
|---|---|
| `0002` | expressible from a design file |
| `0003` | derivable automatically from `hdlname` |
| `0004` | survivable — legalisation can reach the region |
| `0005` | stable — post-place repair stops undoing them |

All four apply cleanly in sequence to a clean tree (verified with `git apply`).
They share `place_common.cc/h` and `command.cc`, so apply them in order.

`0002` and `0003` are separate submissions: the attribute path is useful on its
own, while `0003` depends on yosys preserving `hdlname` (see
`../upstream-issue-3-yosys-hdlname-loss.md`). Measured on this design, nextpnr
reports:

```
Info: Hierarchy floorplan: 2 of 70774 cells carry hdlname.
```

so it correctly declines to build a floorplan from two cells. Until yosys is
fixed, the attribute path in the same patch is the usable one.

## 0002 — JSON region attributes

**Lets a floorplan travel in the design file instead of requiring a Python hook.**

nextpnr has had a Region API for years — `createRectangularRegion` /
`constrainCellToRegion`, honoured by HeAP (`placer_heap.cc:892-900` clamps the
analytical solve via `limit_to_reg`, `:1047` limits spreader radius) and by
`placer1` via `check_cell_bel_region`. But there is **no way to express a region
from a JSON design**. The only route is a `--pre-place` Python script, which:

* requires nextpnr built **with** Python bindings — a build option many
  distributions and CI images leave off; and
* on the xilinx arch additionally needs `getBelLocation` bound, which upstream
  does not do at all.

So any floorplan built on the Python hook cannot run on a stock nextpnr.

### What it adds

```
design attribute:  nextpnr_regions = "name:x0,y0,x1,y1;name2:x0,y0,x1,y1;..."
cell attribute:    REGION          = "name"
```

Module attributes already land in `ctx->attrs` (`frontend/frontend_base.h:279`)
and cell attributes in `ci->attrs` (`:492`), so no frontend change is needed —
only the code to act on them.

The naming deliberately mirrors the existing `BEL` attribute convention, which
the placer already reads to pin a cell to a site. `REGION` is the same idea one
level coarser: `BEL` fixes a cell to a bel, `REGION` confines it to a box.

Applied in `command.cc` **before** `run_script_hook("pre-place")`, so an existing
Python script can still override it.

Malformed entries are counted and skipped with a warning rather than aborting the
run. A floorplan is an optimisation hint; refusing to place a design because one
box is mistyped would be a poor trade.

### Why it is worth having

On this design (OdoCrypt miner, xc7k325t, ~70k cells) the floorplan could
otherwise reach only the 420 cells something else had already constrained — 0.6%
of the netlist — because 99.4% of cells are anonymous after synthesis. Driving
regions from the design file lifted that to **50,972 cells**, and post-placement
Fmax from 97.47 MHz to 116.75 MHz.

*(Caveat, stated so nobody adopts this on an inflated claim: that run then failed
to route on an intra-site `CARRY4_CO1 → CFFMUX_OUT` arc, after post-place repair
relocated 13,862 stranded cells. Region constraints interact badly with cluster
legalisation when the boxes are tight. The mechanism is sound; the geometry needs
work, and that is a user-side concern rather than a defect in this patch.)*

### Verified

```
Info: Applied 21 region(s) from design attributes, constraining 50972 cell(s).
```

with **no `--pre-place` flag**, on a design whose region boxes were generated
without any nextpnr involvement at all — i.e. exactly what a user without the
local `getBelLocation` patch can do.

### Status

Not yet submitted. Needs `gh auth login` (or a manual PR) to file.

## 0003 — derive a floorplan from `hdlname`, self-anchoring

Adds `--floorplan-hierarchy`: nextpnr groups cells by RTL scope taken from the
yosys `hdlname` attribute, picks the grouping depth itself, and confines each
group to a region. **No external tooling at any stage.**

```
before:  yosys -> floorplan script -> group script -> bake script -> nextpnr
after:   yosys -> nextpnr --floorplan-hierarchy
```

### Self-anchoring is what makes it standalone

An earlier version only created a region for a group that already had an
*anchor* — a cell pinned by a `BEL` attribute — which in practice came from an
external floorplanning script. That made an in-tool feature depend on out-of-tool
geometry, and on a design with nothing pre-placed it silently produced **zero
regions** while reporting success.

The dependency was never necessary. Such a script has to harvest a throwaway
placement to discover where the usable bels are; nextpnr reads that from the
chipdb (`getBels()` / `getBelType()` / `getBelLocation()`). The tool knows the
device better than a script inferring it from a trial run.

When a group has no anchor, its region is now derived from the device: the Y
extent from the chipdb, split one band per group, in pipeline order.
Deterministic, no trial placement, works on a design that has never been placed.

Anchors still win where they exist — an explicit `BEL` constraint is a stronger
statement of intent than a derived band, so this is a fallback, not a
replacement.

### Design choices, each from a measured failure

* **Depth is derived, not constant** — the shallowest whose largest group is
  under a fraction of the design. Coverage cannot be the criterion: every depth
  covers every cell, including one that puts 77% of the design in a single box.
* **Groups ordered by trailing integer**, not lexically. `round10` would
  otherwise sort between `round1` and `round2`, scattering adjacent pipeline
  stages into non-adjacent bands.
* **Anchors filtered by 1.5×IQR** — a single clock/IO cell falling into a group
  stretched one region to 227 tiles against ~40 for its peers, leaving that group
  effectively unconstrained while appearing handled.
* **`BEL` read from attributes, not `cell->bel`** — this runs before placement,
  so nothing is bound yet.

### Honest status

Depends on yosys preserving `hdlname` (see
`../patches-yosys/`). Without it nextpnr reports `2 of 70774 cells carry hdlname`
on a real design and correctly declines.

**No timing benefit has been demonstrated.** Region-constrained placement was
measured repeatedly on this design and routed worse than unconstrained placement
every time — three runs, none converging, against a baseline that reached zero
overuse in 22 iterations. The mechanism is sound and the geometry is derived
rather than guessed; whether hierarchy regions *help* is unproven and on this
design they hurt.

## 0004 — strict legalisation clamps its search into the region

`legalise_placement_strict()` (`common/placer_heap.cc`) centres its random search
on the cell's **current** location and only clamps the **radius** to half the
region's size; a candidate outside the region is then rejected, never clipped. A
cell the spreader has moved out of its own region therefore samples points that
can never be accepted, until the attempts budget runs out and it reports a
**utilisation** error — on a design using well under half the device.

The clamp is inverted with respect to difficulty: the smaller the region, the
narrower the search, so the hardest case gets the least reach.

Fix: clamp the sample into the region bounds.

Honest sizing: on its own this moved stranded cells only 13862 → 13626 (1.7%),
because the dominant relocation happens later, in the pass `0005` addresses. It
did improve post-place Fmax 116.75 → 121.88 MHz. Worth having, but `0005` is the
bigger effect.

## 0005 — post-place cluster repair respects regions

`xilinx/arch_place.cc` relocates clusters whose placement came out invalid,
checking bel type, availability, `isValidBelForCell` and `cluster_bels` — but
**not** regions. `check_cell_bel_region()` is referenced only from
`common/placer1.cc`; nothing in the xilinx placement path consults it.

So a region-constrained cell can be moved out of its region by a pass that never
looks at the constraint. That is a defect regardless of how often it fires.

### Measured effect on this design: NONE

Stated plainly, because an earlier draft of this file claimed the opposite.

With and without the patch, on a 21-region / 50,972-cell floorplan:

```
relocated 13626 stranded cluster(s)/cell(s)     <- identical
post-place clk_h 121.88 MHz                     <- identical
```

The placement is bit-for-bit the same. `check_cell_bel_region()` returns true for
cells with no region, and the cells this pass relocates turn out not to be
region-constrained ones.

The earlier claim — that repair was "undoing a quarter of the floorplan", 13626
of 50972 cells being 27% — was inference from a coincidental ratio. It was never
verified, and the measurement contradicts it.

### Why it is a no-op here, and when it would not be

Repair searches outward from the cluster's current position and takes the first
valid candidate, typically a tile or two away. With the regions used here
(BRAM extent + 30 tiles of padding) such a short move stays inside the box, so
the region check passes trivially.

It would bite with tight regions — but the tight geometry (pad 12) fails
legalisation before reaching repair, so the case where this patch matters is
currently the case that does not run.

### Status

Submit as a correctness fix, not a performance one. No benchmark supports it.
Instrumenting the reject count would turn "no effect" from inference into
measurement, and is worth doing before submission.
