# nextpnr: strict legalisation cannot place cells into a region it has moved them out of

**Target:** [YosysHQ/nextpnr](https://github.com/YosysHQ/nextpnr) — defect
**File:** `common/placer_heap.cc`, `legalise_placement_strict()`
**Symptom:** `ERROR: Unable to find legal placement for cell '...', check constraints and utilisation.` on a design that is nowhere near its utilisation limit.

## Summary

When a region-constrained cell has to be legalised, the search for a free bel is
**centred on the cell's current location** and merely has its **radius clamped to
half the region's size**. The sampled candidate is then *rejected* if it lies
outside the region — never clipped into it.

If the analytical solve or the spreader has moved a cell outside its own region
(which happens routinely, since spreading relieves density without regard to
region membership), the search window is centred outside the region and is at
most half the region wide. Most or all samples miss, every one is rejected, and
the loop spins until the attempts budget is exhausted.

The error then blames utilisation, which sends you looking in the wrong place.
The design here uses well under half the device.

## The code

```cpp
// common/placer_heap.cc, legalise_placement_strict()
int rx = radius, ry = radius;

if (ci->region != nullptr) {
    rx = std::min(radius, (constraint_region_bounds[ci->region->name].x1 -
                           constraint_region_bounds[ci->region->name].x0) / 2 + 1);
    ry = std::min(radius, (constraint_region_bounds[ci->region->name].y1 -
                           constraint_region_bounds[ci->region->name].y0) / 2 + 1);
}

int nx = ctx->rng(2 * rx + 1) + std::max(cell_locs.at(ci->name).x - rx, 0);
int ny = ctx->rng(2 * ry + 1) + std::max(cell_locs.at(ci->name).y - ry, 0);
```

and further down, the candidate is discarded rather than corrected:

```cpp
for (auto sz : fb.at(nx).at(ny)) {
    if (ci->region != nullptr && ci->region->constr_bels && !ci->region->bels.count(sz))
        continue;
```

Note the radius clamp is **inverted with respect to difficulty**: the smaller the
region, the smaller `rx`/`ry`, so the narrower the search — meaning the harder
case (a cell stranded far from a small region) gets the *least* reach.

## Evidence

xc7k325t, ~70k cells, 21 rectangular regions covering 50,972 cells, all created
with `createRectangularRegion` (so `constr_bels = true`):

| region geometry | result |
|---|---|
| tight boxes (BRAM extent + 12 tiles) | `Unable to find legal placement` |
| same + 30 tiles | legalises, but `post-place repair: relocated 13862 stranded cluster(s)/cell(s)` |
| Y-bands, 1.8× overlap | `Unable to find legal placement` |

Strictly monotonic in how much slack the region has. That is the signature of a
search that cannot *reach* its target, not of a capacity limit — and the
13,862-cell "stranded" repair count in the case that does survive shows how many
cells the legaliser failed to place properly even then.

## Suggested fix

Clamp the sample into the region rather than only shrinking its radius:

```cpp
if (ci->region != nullptr && ci->region->constr_bels) {
    const auto &rb = constraint_region_bounds[ci->region->name];
    nx = std::min(std::max(nx, rb.x0), rb.x1);
    ny = std::min(std::max(ny, rb.y0), rb.y1);
}
```

The search then always lands inside the only area the cell may legally occupy.
This only affects cells that have a region, so designs using none are unaffected.

A fuller fix would also centre the window on the clamped position rather than on
the cell's stale location, so the radius growth is measured from somewhere useful.

## Why this matters

Region constraints are the natural mechanism for floorplanning, hierarchy-aware
placement, and incremental P&R, and nextpnr has had the API for years. In
practice they are barely usable on a large design: any region tight enough to
influence placement is tight enough to make legalisation fail. Fixing this makes
an existing feature work rather than adding a new one.

Related: nextpnr also has no way to express a region from a JSON design — the only
route is a `--pre-place` Python script, and Python bindings are a build option. A
separate patch adds `nextpnr_regions` / `REGION` attribute support; the two
together make floorplanning usable from a plain design file.
