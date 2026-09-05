#!/usr/bin/env python3
"""
Check whether a nextpnr placement can actually be reattached to Vivado's netlist,
and emit the XDC only if it can.

WHY
---
The first attempt at "nextpnr place -> Vivado route" applied 0 of 141548
constraints and the run aborted on its validity gate. Two independent bugs:

  1. netlist_for_vivado.v was written WITHOUT -norename, so yosys had rewritten
     every internal cell to '_62672_' while the nextpnr JSON still held
     '$flatten\\...\\worker.\\compare.$lt$...'. Nothing could ever have matched.
     Fixed by make_vivado_netlist.ys.

  2. This script's predecessor applied name.replace('.', '/') to convert yosys
     hierarchy to Vivado hierarchy. But the design is FLATTENED -- the names are
     literal, not hierarchical -- and the substitution corrupted auto-generated
     names that embed source paths: '.../miner.v:47$39322' became
     '.../miner/v:47$39322'. That substitution is gone.

Rather than guess at the name format a third time, this diffs against ground
truth dumped from Vivado itself (vivado_dump_cellnames.tcl) and REPORTS THE
MATCH RATE before any expensive routing runs.

EXPECTED SHORTFALL
------------------
nextpnr packs, so a small set of its cells legitimately do not exist in the
pre-pack netlist. Measured on placed_yb.json: 275 '$PACKER' cells and 751
'$LUT$' split cells out of 70774 -- about 1.5%. Anything much worse than that
means the mapping is still wrong, not that packing is to blame.

USAGE
    ./check_placement_names.py placed_yb.json vivado_cellnames.txt out.xdc
"""
import json
import sys
from collections import Counter


def load_nextpnr(path):
    d = json.load(open(path))
    mods = d["modules"]
    top = next((m for m in mods if mods[m].get("attributes", {}).get("top")), list(mods)[0])
    return mods[top]["cells"]


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    placed, namefile, outfile = sys.argv[1], sys.argv[2], sys.argv[3]

    # Ground truth: what Vivado calls its cells.
    vivado = set()
    for line in open(namefile):
        line = line.rstrip("\n")
        if not line:
            continue
        vivado.add(line.split("\t")[0])
    print("Vivado netlist: %d primitive cells" % len(vivado))

    cells = load_nextpnr(placed)
    print("nextpnr placed: %d cells" % len(cells))

    matched, unmatched = [], []
    reasons = Counter()
    for name, cell in cells.items():
        bel = cell.get("attributes", {}).get("NEXTPNR_BEL")
        if not bel or "/" not in bel:
            reasons["no NEXTPNR_BEL"] += 1
            continue
        site, belname = bel.rsplit("/", 1)
        # NO name rewriting. The design is flat; names are literal.
        if name in vivado:
            matched.append((name, site, belname))
        else:
            unmatched.append(name)
            if "$PACKER" in name:
                reasons["$PACKER (nextpnr-created)"] += 1
            elif "$LUT$" in name:
                reasons["$LUT$ (nextpnr LUT split)"] += 1
            else:
                reasons["UNEXPECTED -- mapping still wrong"] += 1

    placeable = len(matched) + len(unmatched)
    frac = len(matched) / placeable if placeable else 0.0
    print("\nmatched   %d" % len(matched))
    print("unmatched %d" % len(unmatched))
    print("match rate %.2f%%" % (frac * 100))
    print("\nunmatched breakdown:")
    for k, v in reasons.most_common():
        print("   %-32s %d" % (k, v))

    unexpected = reasons["UNEXPECTED -- mapping still wrong"]
    if unexpected:
        print("\nfirst 5 unexpected names (these should have matched):")
        for n in [u for u in unmatched if "$PACKER" not in u and "$LUT$" not in u][:5]:
            print("   %s" % n)

    if frac < 0.90:
        print("\nREFUSING to write XDC: match rate %.2f%% is below 90%%." % (frac * 100))
        print("Vivado would route a DIFFERENT placement, making the comparison")
        print("meaningless. Fix the name mapping first.")
        return 1

    with open(outfile, "w") as f:
        f.write("# nextpnr placement as Vivado constraints\n")
        f.write("# source: %s\n" % placed)
        f.write("# matched %d / %d cells (%.2f%%)\n\n" % (len(matched), placeable, frac * 100))
        for name, site, belname in matched:
            esc = "{%s}" % name
            f.write("set_property LOC %s [get_cells %s]\n" % (site, esc))
            f.write("set_property BEL %s [get_cells %s]\n" % (belname, esc))
    print("\nwrote %d constraints to %s" % (len(matched) * 2, outfile))
    return 0


if __name__ == "__main__":
    sys.exit(main())
