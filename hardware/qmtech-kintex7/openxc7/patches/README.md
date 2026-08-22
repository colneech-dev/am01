# nextpnr patches

Patches against [nextpnr](https://github.com/YosysHQ/nextpnr) (applied here to
the `nextpnr-xilinx` fork) that are candidates for upstream submission.

## Submission order

These are interdependent. Submitting only the first would let a user *express* a
floorplan that then fails to legalise, which is worse than not having it:

| patch | makes floorplans... |
|---|---|
| `0002` | expressible from a design file, and derivable from `hdlname` |
| `0003` | survivable — legalisation can reach the region |
| `0004` | stable — post-place repair stops undoing them |

`0002` contains **two logically separate changes** that happen to touch the same
files (`place_common.cc/h`, `command.cc`). Split them before submitting:

1. `nextpnr_regions` / `REGION` attribute support — `apply_region_constraints()`
2. `--floorplan-hierarchy`, deriving a floorplan from `hdlname` —
   `derive_hierarchy_floorplan()`

The second depends on yosys preserving `hdlname` (see
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

## 0003 — strict legalisation clamps its search into the region

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
because the dominant relocation happens later, in the pass `0004` addresses. It
did improve post-place Fmax 116.75 → 121.88 MHz. Worth having, but `0004` is the
bigger effect.

## 0004 — post-place cluster repair respects regions

`xilinx/arch_place.cc` relocates clusters whose placement came out invalid,
checking bel type, availability, `isValidBelForCell` and `cluster_bels` — but
**not** regions. `check_cell_bel_region()` is referenced only from
`common/placer1.cc`; nothing in the xilinx placement path consults it.

So on a region-constrained design:

```
HeAP places with regions           honoured
post-place repair relocates cells  REGIONS IGNORED   <-- 13626 of 50972 cells (27%)
placer1 refinement                 honoured again
routing                            fails on intra-site arcs
```

A quarter of the floorplan is undone immediately after being built, which is why
the subsequent route failed on an intra-site `CARRY4_CO1 → CFFMUX_OUT` arc.

Fix: check the region for the cluster root and for every member. Members can have
different regions from the root — a LUT/FF pair can straddle two RTL scopes.
`check_cell_bel_region()` returns true for cells with no region, so unconstrained
designs are unaffected.
