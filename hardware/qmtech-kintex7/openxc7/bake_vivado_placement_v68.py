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
PLACEMENT = BASE + "vivado_placement_norename_v68.txt"


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: bake_vivado_placement.py <in.json> <out.json>")
    infile, outfile = sys.argv[1], sys.argv[2]

    # vivado_place_export_v68.tcl writes four tab-separated columns:
    #     NAME \t LOC \t BELNAME \t REF_NAME
    # nextpnr wants the BEL attribute as "SITE/BEL", e.g. SLICE_X32Y245/D6LUT.
    # (The older vivado_placement.txt was two columns with SITE/BEL already
    # joined, but its cell names are the _NNNNN_ form from write_verilog
    # WITHOUT -norename, so it cannot be matched against the yosys netlist.)
    place = {}
    skipped = 0
    with open(PLACEMENT, errors="replace") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 3:
                name, loc, belname = parts[0], parts[1], parts[2]
                if not loc or not belname:
                    skipped += 1
                    continue
                place[name] = "%s/%s" % (loc, belname)
            elif len(parts) == 2 and "/" in parts[1]:
                place[parts[0]] = parts[1]
            else:
                skipped += 1
    print("vivado placements read: %d  (skipped %d malformed/unplaced)"
          % (len(place), skipped))

    print("loading %s ..." % infile)
    design = json.load(open(infile))
    mods = design["modules"]
    top = next(m for m in mods if mods[m].get("attributes", {}).get("top"))
    cells = mods[top]["cells"]
    print("cells in netlist     : %d" % len(cells))

    # Cell types whose BEL naming differs between Vivado and nextpnr. Vivado
    # reports the clock buffer as BUFGCTRL_X0Y1/BUFG (bel type BUFG_BUFG) while
    # nextpnr's packed cell is type BUFGCTRL, and binding fails hard:
    #     ERROR: Bel 'BUFGCTRL_X0Y1/BUFG' of type 'BUFG_BUFG' does not match
    #            cell '$auto$clkbufmap.cc:261:execute$598448' of type 'BUFGCTRL'
    # These are a handful of cells out of 70071. Leaving them free costs
    # nothing and keeps the experiment valid, exactly as excluding the SRLs did
    # for the nextpnr-placement -> Vivado-router direction.
    # CARRY4 is also excluded, for a different reason: nextpnr places carry
    # chains as CLUSTERS with relative z offsets (constr_children), so pinning
    # the root to a Vivado BEL violates its own consistency check:
    #     ERROR: constraint satisfaction check failed for cell
    #            '...carry4' at Bel 'SLICE_X17Y261/CARRY4' (z=79 cz=-2147...)
    # This design has only 100 CARRY4 cells, so leaving those clusters free
    # costs almost nothing and keeps the other 68k constraints valid.
    SKIP_PREFIX = ("BUFG", "MMCM", "PLL", "IBUF", "OBUF", "IOB", "BUFH", "BUFR",
                   "CARRY")

    applied = 0
    missing = 0
    skipped_type = 0
    for name, cell in cells.items():
        bel = place.get(name)
        if bel is None:
            missing += 1
            continue
        ctype = cell.get("type", "")
        if ctype.startswith(SKIP_PREFIX) or "/BUFG" in bel or "BUFGCTRL" in bel:
            skipped_type += 1
            continue
        cell.setdefault("attributes", {})["BEL"] = bel
        applied += 1
    print("skipped by type      : %d (clock/IO, naming differs between tools)"
          % skipped_type)

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
