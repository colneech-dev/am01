# nextpnr patches

Patches against [nextpnr](https://github.com/YosysHQ/nextpnr) (applied here to
the `nextpnr-xilinx` fork) that are candidates for upstream submission.

## 0001-nextpnr-json-region-attributes.patch

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
