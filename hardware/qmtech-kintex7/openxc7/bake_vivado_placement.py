#!/usr/bin/env python3
"""Bake Vivado's full placement into a nextpnr JSON as BEL attributes.

WHY
---
Four quadrants of the place/route matrix; three are measured:

    place     route     clk_h
    nextpnr   nextpnr   89.30 -> 93.28 (BRAM floorplan + CRIT_DIST_EXP)
    nextpnr   Vivado    63.55
    Vivado    Vivado    158.81
    Vivado    nextpnr   NEVER RUN     <- this script

That last cell decides where the remaining 1.7x gap lives. If nextpnr's router
on Vivado's placement approaches 158, placement is the whole story and the work
is to mimic it. If it lands near 90, the router shares the blame and copying
placement will not rescue it.

Note the second row: Vivado's router on OUR placement scores 63.55, BELOW our
own router's 89.30. So our placement is not merely worse -- it is actively hard
to route, in a way even a commercial router cannot recover.

INPUT
-----
vivado_placement.txt, tab-separated, 70007 cells:

    <hier cell name>\t<SITE>/<BEL>

e.g.  ...crypter.round0.sboxes.sbox11inst.mem.0.0\tRAMB18_X1Y124/RAMB18E1
      ...some_lut\tSLICE_X12Y34/A6LUT

nextpnr honours a cell's BEL attribute as a hard placement constraint, so
setting it for every cell fully determines placement.

NAME MAPPING
------------
Vivado's export uses '.' hierarchy separators; the nextpnr JSON uses the same
yosys names, so most match directly. Cells that do not match are reported and
left free rather than guessed at -- a wrong BEL is worse than none, and the
count is the honest measure of how complete this experiment is.
"""
import json
import sys

BASE = "/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7/"
PLACEMENT = BASE + "vivado_placement.txt"


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: bake_vivado_placement.py <in.json> <out.json>")
    infile, outfile = sys.argv[1], sys.argv[2]

    place = {}
    with open(PLACEMENT, errors="replace") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 2:
                continue
            name, siteBel = parts
            if "/" not in siteBel:
                continue
            place[name] = siteBel
    print("vivado placements read: %d" % len(place))

    print("loading %s ..." % infile)
    design = json.load(open(infile))
    mods = design["modules"]
    top = next(m for m in mods if mods[m].get("attributes", {}).get("top"))
    cells = mods[top]["cells"]
    print("cells in netlist     : %d" % len(cells))

    applied = 0
    missing = 0
    for name, cell in cells.items():
        bel = place.get(name)
        if bel is None:
            missing += 1
            continue
        cell.setdefault("attributes", {})["BEL"] = bel
        applied += 1

    print("BEL attributes set   : %d" % applied)
    print("cells left free      : %d  (%.1f%%)"
          % (missing, 100.0 * missing / max(1, len(cells))))
    if applied == 0:
        sys.exit("ERROR: nothing matched -- name mapping is wrong, not worth running")

    with open(outfile, "w") as f:
        json.dump(design, f)
    print("wrote %s" % outfile)


if __name__ == "__main__":
    main()
