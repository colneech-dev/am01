#!/usr/bin/env python3
"""Replicate high-fanout drivers, partitioning loads by PLACEMENT.

WHY A SECOND VERSION
--------------------
replicate_fanout.py partitioned loads into contiguous chunks in NETLIST order,
on the assumption that adjacent bits of a wide register place near each other.
Measured A/B on seed 3, same floorplan, only the replicas differing:

    without replication   129.79 MHz
    with, netlist order   110.99 MHz     <- 18.8 MHz WORSE

So the proxy is wrong. Netlist order does not track placement, so each copy
ended up driving loads scattered across the die: seven drivers each spanning a
wide box, where the original at least sat at the centroid of everything.

This is what Vivado does differently. phys_opt_design replicates AFTER
placement, when it knows where every load physically is. Doing it before
placement throws away precisely the information that makes it work.

THE FIX, AND WHY IT IS SIMPLER THAN IT SOUNDS
---------------------------------------------
The replicas do not need to be placed by hand. If each replica's load group is
spatially COMPACT, HeAP will pull that replica to the group's centroid by
itself -- that is what an analytical placer does. So all that is required is to
partition the loads by where they actually landed in a previous placement.

Two-pass flow:
    1. place once            -> placed_*.json carries NEXTPNR_BEL per cell
    2. this script           -> partition loads spatially, emit replicas
    3. place and route again -> HeAP puts each replica near its own group

Partitioning is by sorted (y, x) chunked into N bands. Bands, not a general
clustering, because the fabric is column-structured and a band keeps each group
within a narrow row range -- which is the axis that mattered for the BRAM
floorplan too (y-base was worth +29 MHz, column count +/-2).

Usage:
    replicate_fanout_placed.py <orig.json> <placed.json> <out.json>
        [--threshold N] [--per-copy N] [--dry-run]
"""
import argparse
import json
import re
import sys
from collections import defaultdict

OUT_PORTS = {"Q", "O", "O6", "O5"}
REPLICABLE = ("FD", "LUT", "SRL")
SITE_RE = re.compile(r"(?:SLICE|RAMB18|DSP48)_X(\d+)Y(\d+)")


def bisect_groups(points, n):
    """Split points into n spatially compact groups by recursive bisection.

    points: [(y, x, ...)] ; returns [[point, ...], ...]

    Sorting by (y, x) and chunking gives horizontal STRIPS: measured on the
    643-load net those were 5-35 rows tall but still 50 columns wide, so each
    driver still had to reach across the die horizontally. Splitting the wider
    axis at each step keeps groups compact in BOTH directions, which is the
    point of replicating at all.
    """
    groups = [list(points)]
    while len(groups) < n:
        # split the group whose bounding box is largest
        gi = max(range(len(groups)),
                 key=lambda i: (max(p[0] for p in groups[i]) - min(p[0] for p in groups[i]))
                             + (max(p[1] for p in groups[i]) - min(p[1] for p in groups[i]))
                 if len(groups[i]) > 1 else -1)
        g = groups[gi]
        if len(g) < 2:
            break
        dy = max(p[0] for p in g) - min(p[0] for p in g)
        dx = max(p[1] for p in g) - min(p[1] for p in g)
        g.sort(key=(lambda p: (p[0], p[1])) if dy >= dx else (lambda p: (p[1], p[0])))
        mid = len(g) // 2
        groups[gi:gi + 1] = [g[:mid], g[mid:]]
    return [g for g in groups if g]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("infile", help="original (unplaced) netlist to modify")
    ap.add_argument("placed", help="placed netlist, for load positions")
    ap.add_argument("outfile", nargs="?")
    ap.add_argument("--threshold", type=int, default=200)
    ap.add_argument("--per-copy", type=int, default=100)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    # ---- positions from the placed run -------------------------------------
    print("reading placement from %s ..." % args.placed)
    pd = json.load(open(args.placed))
    pmods = pd["modules"]
    ptop = next(m for m in pmods if pmods[m].get("attributes", {}).get("top"))
    pos = {}
    for name, c in pmods[ptop]["cells"].items():
        a = c.get("attributes", {})
        bel = a.get("NEXTPNR_BEL") or a.get("BEL", "")
        m = SITE_RE.search(bel)
        if m:
            pos[name] = (int(m.group(1)), int(m.group(2)))
    print("  placed cells: %d" % len(pos))
    del pd, pmods

    # ---- the netlist we actually modify ------------------------------------
    print("loading %s ..." % args.infile)
    design = json.load(open(args.infile))
    mods = design["modules"]
    top = next(m for m in mods if mods[m].get("attributes", {}).get("top"))
    cells = mods[top]["cells"]

    maxbit = 1
    driver = {}
    loads = defaultdict(list)
    for name, c in cells.items():
        for port, bits in c.get("connections", {}).items():
            for i, b in enumerate(bits):
                if not isinstance(b, int):
                    continue
                if b > maxbit:
                    maxbit = b
                if port in OUT_PORTS:
                    driver[b] = name
                else:
                    loads[b].append((name, port, i))

    targets = []
    for bit, drv in driver.items():
        n = len(loads.get(bit, ()))
        if n <= args.threshold:
            continue
        if not cells[drv].get("type", "").startswith(REPLICABLE):
            continue
        targets.append((n, bit, drv))
    targets.sort(reverse=True)
    print("drivers above threshold %d: %d" % (args.threshold, len(targets)))

    added = 0
    for n, bit, drv in targets:
        ld = loads[bit]
        # keep only loads we know the position of; unplaced ones stay on the
        # original driver rather than being assigned to an arbitrary copy
        known = [(pos[c][1], pos[c][0], c, p, i) for (c, p, i) in ld if c in pos]
        unknown = [(c, p, i) for (c, p, i) in ld if c not in pos]
        if len(known) < 2:
            print("  %-50s no placement data, skipping" % drv[-50:])
            continue
        ncopies = max(2, (len(known) + args.per_copy - 1) // args.per_copy)
        bands = bisect_groups(known, ncopies)

        ys = [k[0] for k in known]
        xs = [k[1] for k in known]
        print("  %-50s %4d loads (dx %d dy %d) -> %d groups, %d unplaced kept"
              % (drv[-50:], len(ld), max(xs) - min(xs), max(ys) - min(ys),
                 len(bands), len(unknown)))
        if args.dry_run:
            for k, band in enumerate(bands):
                by = [b[0] for b in band]
                bx = [b[1] for b in band]
                print("      group %d: %3d loads  dy %-3d dx %-3d"
                      % (k, len(band), max(by) - min(by), max(bx) - min(bx)))
            continue

        src = cells[drv]
        for k in range(1, len(bands)):
            band = bands[k]
            if not band:
                continue
            maxbit += 1
            newbit = maxbit
            newname = "%s$rep%d" % (drv, k)
            newcell = json.loads(json.dumps(src))
            for port, bits in newcell["connections"].items():
                if port in OUT_PORTS:
                    newcell["connections"][port] = [newbit if b == bit else b
                                                    for b in bits]
            newcell.setdefault("attributes", {})["keep"] = \
                "00000000000000000000000000000001"
            cells[newname] = newcell
            added += 1
            for (_y, _x, lname, lport, lidx) in band:
                cells[lname]["connections"][lport][lidx] = newbit

    print("added %d replica cells" % added)
    if args.dry_run:
        print("(dry run, nothing written)")
        return
    if not args.outfile:
        sys.exit("ERROR: outfile required unless --dry-run")
    with open(args.outfile, "w") as f:
        json.dump(design, f)
    print("wrote %s" % args.outfile)


if __name__ == "__main__":
    main()
