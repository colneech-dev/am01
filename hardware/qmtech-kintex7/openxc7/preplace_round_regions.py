"""
nextpnr --pre-place hook: confine each OdoCrypt round's logic to a region around
that round's BRAMs.

WHY
---
floorplan_stripe.py can only address 420 of 69869 cells (0.6%), because 99.4% of
the netlist is anonymous ($abc$...parse_blif$N LUTs, $auto$ff.cc:337:slice$N FFs).
Every floorplan tried this session -- striped 102.15 MHz, Y-band 92.36 MHz -- was a
rearrangement of that same 0.6%, which is why so much placer tuning refuted.

The measured critical path is not BRAM-limited. Same arc, both tools:

    Vivado  RAMB18E1 2.080 -> net(fo=7) 3.146 -> LUT6 -> net 0.641 -> LUT2 -> FDRE
    ours    RAMB18   2.1   -> net       6.9   -> LUT6 -> net 1.3   -> LUT6 -> FDRE

Identical structure. The gap is one net: 3.146 vs 6.9 ns. It ends at a LUT sitting
at tile (113,251) whose BRAM is at (19,5) -- and that LUT had no name any floorplan
could reach. derive_round_index.py recovers a round index for 51621 cells from NET
names (LUT6 95.2%, LUT2 96.5%, FDRE 69.8%, BRAM 100%), which is what makes this
possible.

WHY REGIONS AND NOT BELs
------------------------
The existing floorplan pins cells to exact BELs. Doing that to 51621 cells would
over-constrain the placer hopelessly. nextpnr's Region is a soft bounding box:
placer_heap.cc:892-900 clamps the analytical solve to the region (limit_to_reg) and
:1047 limits the spreader radius, so the constraint acts where placement is
actually decided while leaving freedom inside the box.

GEOMETRY
--------
Each round's box is derived from where that round's own BRAMs were placed, then
padded. Nothing is hardcoded, so this composes with whatever floorplan_stripe.py
did rather than contradicting it.

USAGE
    nextpnr-xilinx ... --pre-place preplace_round_regions.py
    (env) ROUND_MAP  path to cell_rounds.json   [out_nm1_nosr/cell_rounds.json]
    (env) ROUND_PAD  tiles of padding around each round's BRAM bbox  [default 12]
"""
import json
import os
from collections import defaultdict

ROUND_MAP = os.environ.get("ROUND_MAP", "out_nm1_nosr/cell_rounds.json")
PAD = int(os.environ.get("ROUND_PAD", "12"))

print("preplace_round_regions: reading %s" % ROUND_MAP)
cell_round = json.load(open(ROUND_MAP))
print("preplace_round_regions: %d cell->round entries" % len(cell_round))

# nextpnr has packed by now, so its cell names are not exactly the synthesis
# netlist's. Report the overlap rather than assuming it -- a low match rate means
# the regions cover little and the experiment says nothing.
present = {}
for cname, cell in ctx.cells:  # noqa: F821  (ctx is injected by nextpnr)
    if cname in cell_round:
        present[cname] = cell_round[cname]
print("preplace_round_regions: matched %d of %d nextpnr cells"
      % (len(present), len(list(ctx.cells))))  # noqa: F821

# Round bounding boxes, taken from the BRAMs already constrained by the floorplan.
bbox = {}
for cname, r in present.items():
    cell = ctx.cells[cname]  # noqa: F821
    bel = getattr(cell, "bel", None)
    if bel is None:
        continue
    try:
        loc = ctx.getBelLocation(bel)  # noqa: F821
    except Exception:
        continue
    if r not in bbox:
        bbox[r] = [loc.x, loc.y, loc.x, loc.y]
    else:
        b = bbox[r]
        b[0] = min(b[0], loc.x)
        b[1] = min(b[1], loc.y)
        b[2] = max(b[2], loc.x)
        b[3] = max(b[3], loc.y)

print("preplace_round_regions: %d rounds have a BRAM-derived bbox" % len(bbox))
if not bbox:
    print("preplace_round_regions: NO anchored cells -- refusing to constrain.")
    print("  Without BRAM anchors the boxes would be invented, not derived, and")
    print("  the run would measure an arbitrary floorplan rather than this one.")
else:
    per_round = defaultdict(int)
    made = set()
    for r, b in sorted(bbox.items()):
        x0, y0 = max(0, b[0] - PAD), max(0, b[1] - PAD)
        x1, y1 = b[2] + PAD, b[3] + PAD
        name = "round%d" % r
        ctx.createRectangularRegion(name, x0, y0, x1, y1)  # noqa: F821
        made.add(r)
        print("  region %-9s x %3d..%-3d  y %3d..%-3d" % (name, x0, x1, y0, y1))

    skipped = 0
    for cname, r in present.items():
        if r not in made:
            skipped += 1
            continue
        try:
            ctx.constrainCellToRegion(cname, "round%d" % r)  # noqa: F821
            per_round[r] += 1
        except Exception as e:
            skipped += 1
            if skipped < 4:
                print("  could not constrain %s: %s" % (cname[:60], e))

    total = sum(per_round.values())
    print("preplace_round_regions: constrained %d cells, skipped %d" % (total, skipped))
    for r in sorted(per_round):
        print("   round %-3d %6d cells" % (r, per_round[r]))
