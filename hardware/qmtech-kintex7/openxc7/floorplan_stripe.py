#!/usr/bin/env python3
"""
Parameterised BRAM floorplan: N columns per round.

BACKGROUND
----------
Two extremes have been measured on this design (OdoCrypt, 21 rounds x 20 sboxes,
xc7k325t):

  N=1 (block, each round packed into one column)
      wirelength 3,545,752 -- the best of anything tried
      routing COLLAPSED: 717 unrouted by iteration 3, congestion rising
      cause: ~200 BRAM outputs leaving one 10-tile region saturates local egress

  N=7 (full stripe, each round spread over every column)
      wirelength ~4,456,894 -- the worst
      routing PERFECT: 0 unrouted, 0 overused, in 10 iterations, 4/4 seeds
      but net delay ~13 ns on the critical path -> 65 MHz

Vivado, for reference, achieves BOTH on the same part with twice the BRAMs
(NUM_MINERS=2, 840 BRAMs):

      logic 2.186 ns + net 3.787 ns = 5.973 ns -> 162 MHz, WNS +1.327 ns
      critical path also starts at a BRAM, so it is the same physics

Our LOGIC delay already matches Vivado's (~2.1 vs 2.186 ns), which confirms the
2.08 ns clock->DO figure extracted from Vivado's own SDF. The whole 2.5x gap is
net delay -- i.e. placement, not the memories.

So the useful knob is somewhere between the extremes: enough columns per round to
avoid the egress bottleneck, few enough that a round's consumers stay compact.

ROTATION
--------
Consecutive rounds sit at similar Y and are the ones that contend for the same
egress. Rotating which columns each round starts from spreads that contention
without spreading the round itself.

SITES
-----
Site names are taken from a real placement dump, never synthesised. The columns
are SPARSE -- X5 spans Y0..Y139 but holds only 59 sites -- so arithmetic on the
grid produces names that do not exist ("No Bel named RAMB18_X5Y68"). Harvest with:

    nextpnr-xilinx ... --no-route --write placed.json

then read NEXTPNR_BEL off every RAMB18E1 cell.

USAGE
-----
    ./floorplan_stripe.py --cols-per-round 3 in.json out.json
"""
import argparse
import json
import re
import sys
from collections import defaultdict


def harvest_sites(placed_json):
    d = json.load(open(placed_json))
    mods = d["modules"]
    top = next((m for m in mods if mods[m].get("attributes", {}).get("top")), list(mods)[0])
    sites = [c["attributes"]["NEXTPNR_BEL"]
             for c in mods[top]["cells"].values()
             if c["type"] == "RAMB18E1_RAMB18E1"]
    if not sites:
        sys.exit("ERROR: no placed RAMB18E1 cells in %s" % placed_json)
    return sites


def parse_site(b):
    m = re.match(r"RAMB18_X(\d+)Y(\d+)", b)
    return int(m.group(1)), int(m.group(2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("infile")
    ap.add_argument("outfile", nargs="?")
    ap.add_argument("--placed", default="out_nm1_nosr/placed.json",
                    help="placement dump to harvest real site names from")
    ap.add_argument("--cols-per-round", type=int, default=3,
                    help="columns each round is spread across. 1=block (routes badly), "
                         "7=full stripe (routes well, long nets). Try 2-3.")
    ap.add_argument("--no-rotate", action="store_true",
                    help="disable per-round column rotation")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    sites = harvest_sites(args.placed)
    by_col = defaultdict(list)
    for b in sites:
        x, y = parse_site(b)
        by_col[x].append((y, b))
    for x in by_col:
        by_col[x].sort()
    cols = sorted(by_col)
    print("harvested %d sites across %d columns: %s"
          % (len(sites), len(cols), {x: len(by_col[x]) for x in cols}))

    design = json.load(open(args.infile))
    mods = design["modules"]
    top = next((m for m in mods if mods[m].get("attributes", {}).get("top")), list(mods)[0])
    cells = mods[top]["cells"]

    # Group by (miner, round) so NUM_MINERS>1 works: g_miner[N] must not collapse.
    groups = defaultdict(list)
    for name, cell in cells.items():
        if "RAMB" not in cell["type"]:
            continue
        mr = re.search(r"round(\d+)\.", name)
        mm = re.search(r"g_miner\[(\d+)\]", name)
        sb = re.search(r"sbox(\d+)inst", name)
        if not mr:
            sys.exit("ERROR: BRAM with no round in name: %s" % name)
        groups[(int(mm.group(1)) if mm else 0, int(mr.group(1)))].append(
            (int(sb.group(1)) if sb else 0, name))

    keys = sorted(groups)
    total = sum(len(v) for v in groups.values())
    if total != len(sites):
        sys.exit("ERROR: %d BRAMs but %d harvested sites" % (total, len(sites)))
    print("%d BRAMs in %d (miner,round) groups" % (total, len(keys)))

    n = max(1, min(args.cols_per_round, len(cols)))
    cursor = {x: 0 for x in cols}
    assigned = 0

    # The columns are very unevenly populated on this part -- measured
    # {0:67, 1:98, 2:34, 3:82, 4:67, 5:59, 6:13} -- so a fixed rotation exhausts
    # the small ones (X6 has 13 sites) long before the big ones. Choose each
    # round's columns by REMAINING capacity instead, which self-balances and
    # cannot run dry while sites are still free. Rotation is applied as a
    # tie-break among equally-loaded columns, so it still spreads consecutive
    # rounds without overriding capacity.
    for idx, key in enumerate(keys):
        members = sorted(groups[key])
        rot = (idx * n) if not args.no_rotate else 0
        avail = [x for x in cols if cursor[x] < len(by_col[x])]
        avail.sort(key=lambda x: (-(len(by_col[x]) - cursor[x]),
                                  (cols.index(x) - rot) % len(cols)))
        chosen = avail[:n]
        if not chosen:
            sys.exit("ERROR: ran out of BRAM sites")
        placed_here = []
        for j, (_, name) in enumerate(members):
            # Round-robin within the chosen columns, re-picking by remaining
            # capacity if one empties mid-round.
            x = None
            for k in range(len(chosen)):
                cand = chosen[(j + k) % len(chosen)]
                if cursor[cand] < len(by_col[cand]):
                    x = cand
                    break
            if x is None:
                spill = [q for q in cols if cursor[q] < len(by_col[q])]
                if not spill:
                    sys.exit("ERROR: ran out of BRAM sites")
                x = max(spill, key=lambda q: len(by_col[q]) - cursor[q])
            bel = by_col[x][cursor[x]][1]
            cursor[x] += 1
            if not args.dry_run:
                cells[name].setdefault("attributes", {})["BEL"] = bel
            placed_here.append(x)
            assigned += 1
        if idx < 3 or idx == len(keys) - 1:
            print("  miner %d round %2d -> cols %s" % (key[0], key[1], sorted(set(placed_here))))

    print("assigned %d BEL attributes (cols-per-round=%d, rotate=%s)"
          % (assigned, n, not args.no_rotate))
    if args.dry_run:
        print("(dry run)")
        return
    if not args.outfile:
        sys.exit("ERROR: outfile required unless --dry-run")
    json.dump(design, open(args.outfile, "w"))
    print("wrote %s" % args.outfile)


if __name__ == "__main__":
    main()
