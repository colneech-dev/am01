#!/usr/bin/env python3
"""
Bake a computed floorplan into a design JSON, so nextpnr needs no Python at all.

WHY
---
The floorplan is computed by preplace_group_regions.py, a --pre-place hook. That
works, but it can only ever work on a nextpnr built WITH Python bindings, which
is a build option many distributions and CI images leave off -- and on this arch
it additionally needs getBelLocation bound, which upstream does not do at all.
So a hook-based floorplan cannot run on a stock nextpnr.

nextpnr now reads regions straight from the design file (apply_region_constraints
in common/place_common.cc):

    design attr   nextpnr_regions = "name:x0,y0,x1,y1;name2:..."
    cell attr     REGION          = "name"

This writes those attributes, so the floorplan travels with the design. The hook
is then needed only ONCE, to compute the boxes -- turning a BEL name like
"RAMB18_X1Y18/RAMB18E1" into tile coordinates needs the chipdb, which only
nextpnr has. After that it is just numbers in a file, reusable by anyone.

USAGE
    ./bake_regions_into_json.py in.json regions_spec.json out.json
"""
import json
import sys


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    injson, specfile, outjson = sys.argv[1], sys.argv[2], sys.argv[3]

    spec = json.load(open(specfile))
    regions = spec["nextpnr_regions"]
    cell_region = spec["cell_region"]
    print("floorplan: %d regions, %d cells" % (regions.count(";") + 1, len(cell_region)))

    d = json.load(open(injson))
    mods = d["modules"]
    top = next((m for m in mods if mods[m].get("attributes", {}).get("top")), list(mods)[0])
    mod = mods[top]

    mod.setdefault("attributes", {})["nextpnr_regions"] = regions

    cells = mod["cells"]
    applied = 0
    unknown = 0
    for cname, rname in cell_region.items():
        cell = cells.get(cname)
        if cell is None:
            # Cells nextpnr created during packing ($PACKER_*, $LUT$ splits) do
            # not exist in the pre-pack netlist. Expected, and reported rather
            # than silently dropped so a real mismatch is still visible.
            unknown += 1
            continue
        cell.setdefault("attributes", {})["REGION"] = rname
        applied += 1

    json.dump(d, open(outjson, "w"))
    print("wrote %s" % outjson)
    print("  REGION attributes applied : %d" % applied)
    print("  not present in this netlist: %d (packing artefacts)" % unknown)
    if applied == 0:
        print("  ERROR: nothing applied -- the spec does not match this netlist.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
