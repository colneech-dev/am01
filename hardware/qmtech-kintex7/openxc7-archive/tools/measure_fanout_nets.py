#!/usr/bin/env python3
"""Are the high-fanout nets still a problem after the BRAM floorplan?

Item 9b (high-fanout driver replication) was scoped when the 644-fanout net
`crypt.progress[1]` owned all three worst Vivado paths at 15.104 ns. But that
was VIVADO's bottleneck on our OLD placement. Since then the BRAM floorplan
moved us 89.30 -> 129.79 MHz and the critical path changed shape entirely:

    2.1 ns  BRAM clock-to-Q
    3.8 ns  BRAM egress net   (was 8.8 at baseline)
    0.2 ns  LUT
    1.3 ns  LUT -> LUT net
    0.2 ns  LUT

Neither high-fanout net appears in it. So before building a replication pass,
measure whether those nets are still stretched in the CURRENT placement --
building a fix for a problem that has moved is the mistake this project has
made repeatedly.

Reports, for the worst-fanout nets: load count and the placed bounding box.
A net with 640 loads confined to a small box is not a timing problem; the same
net spanning the die is.
"""
import json
import re
import sys
from collections import defaultdict

BASE = "/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7/"


def main():
    placed = sys.argv[1] if len(sys.argv) > 1 else BASE + "out_nm1_nosr/placed_vy40_seed3.json"
    print("loading %s ..." % placed)
    d = json.load(open(placed))
    mods = d["modules"]
    top = next(m for m in mods if mods[m].get("attributes", {}).get("top"))
    cells = mods[top]["cells"]

    # cell -> (x, y) from the BEL attribute nextpnr wrote back
    site_re = re.compile(r"(?:SLICE|RAMB18|DSP48)_X(\d+)Y(\d+)")
    pos = {}
    for name, c in cells.items():
        attrs = c.get("attributes", {})
        bel = attrs.get("NEXTPNR_BEL") or attrs.get("BEL", "")
        m = site_re.search(bel)
        if m:
            pos[name] = (int(m.group(1)), int(m.group(2)))
    print("cells with a placed BEL: %d of %d" % (len(pos), len(cells)))
    if not pos:
        sys.exit("no placement found in this JSON -- pass a placed_*.json")

    # net bit -> driver, sinks
    drivers = {}
    sinks = defaultdict(list)
    for name, c in cells.items():
        for port, bits in c.get("connections", {}).items():
            for b in bits:
                if not isinstance(b, int):
                    continue
                # crude but adequate: Q/O are outputs on the cells that matter
                if port in ("Q", "O", "O6", "O5"):
                    drivers[b] = name
                else:
                    sinks[b].append(name)

    rows = []
    for bit, drv in drivers.items():
        ld = sinks.get(bit, ())
        if len(ld) < 100:
            continue
        pts = [pos[n] for n in ld if n in pos]
        if drv in pos:
            pts.append(pos[drv])
        if len(pts) < 2:
            continue
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        rows.append((len(ld), max(xs) - min(xs), max(ys) - min(ys), bit, drv))

    rows.sort(reverse=True)
    print("\nnets with >=100 loads, by fanout:")
    print("  %-7s %-7s %-7s %s" % ("loads", "dx", "dy", "driver"))
    for n, dx, dy, bit, drv in rows[:12]:
        print("  %-7d %-7d %-7d %s" % (n, dx, dy, drv[:64]))

    if rows:
        print("\n  (for scale: the design's critical BRAM egress net spans "
              "~3.8 ns; a die-wide net is dx~100 dy~250)")


if __name__ == "__main__":
    main()
