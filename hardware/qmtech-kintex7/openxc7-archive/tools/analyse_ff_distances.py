#!/usr/bin/env python3
"""Which register bank is being split, and how bad is it overall?

All 200 worst setup paths on the nextpnr placement have identical shape --
logic 0.322 ns, net ~15 ns, 97.9% routing -- which says a whole bank of
directly-wired flops sits far from its destination rather than one net being
unlucky.

This maps the placement back to RTL:

  * the two flops on the critical path, by hdlname
  * the distance distribution over every flop-to-flop connection, so the scale
    of the locality failure is a number rather than an impression
  * the worst RTL scopes, to name the structure that needs fixing

Placement comes from the XDC (cell -> SLICE_XnYm), connectivity from the
synthesis JSON. Distances are in slice coordinates, matching the critical
path's measured dX 21 / dY 132.
"""
import json
import re
import sys
from collections import Counter, defaultdict

BASE = "/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7"
XDC = BASE + "/out_nm1_nosr/nextpnr_placement_v68.xdc"
JSON = BASE + "/out_nm1_nosr/am01_qmtech_top_v68.json"

CRIT = ["$auto$ff.cc:337:slice$466022", "$auto$ff.cc:337:slice$226497"]

# ---------------------------------------------------------------- placement
loc_re = re.compile(r"^set_property LOC SLICE_X(\d+)Y(\d+) \[get_cells \{(.*)\}\]$")
pos = {}
with open(XDC) as f:
    for line in f:
        m = loc_re.match(line.rstrip("\n"))
        if m:
            pos[m.group(3)] = (int(m.group(1)), int(m.group(2)))
print("placed cells with SLICE LOC: %d" % len(pos))

# ---------------------------------------------------------------- netlist
print("loading netlist (86 MB, takes a moment)...")
with open(JSON) as f:
    d = json.load(f)
mods = d["modules"]
top = next(m for m in mods if mods[m].get("attributes", {}).get("top"))
cells = mods[top]["cells"]
print("cells in netlist: %d" % len(cells))


def hdl(name):
    a = cells.get(name, {}).get("attributes", {})
    return a.get("hdlname") or a.get("src") or "(none)"


print("\n=== the two flops on the critical path ===")
for c in CRIT:
    print("  %s" % c)
    print("    loc     : %s" % (pos.get(c),))
    print("    type    : %s" % cells.get(c, {}).get("type", "(not in netlist)"))
    print("    hdlname : %s" % str(hdl(c))[:150])

# ------------------------------------------------- flop-to-flop connections
# Build net -> (drivers, sinks) over flops only. Yosys FF types on xc7 start
# with FD (FDRE/FDSE/FDCE/FDPE).
def is_ff(name):
    return cells.get(name, {}).get("type", "").startswith("FD")


drivers = {}          # netid -> cell
sinks = defaultdict(list)  # netid -> [cell]
for name, c in cells.items():
    if not is_ff(name):
        continue
    conns = c.get("connections", {})
    for port, bits in conns.items():
        for b in bits:
            if not isinstance(b, int):
                continue
            if port == "Q":
                drivers[b] = name
            elif port == "D":
                sinks[b].append(name)

pairs = []
for netid, drv in drivers.items():
    if drv not in pos:
        continue
    for snk in sinks.get(netid, ()):
        if snk not in pos:
            continue
        dx = abs(pos[drv][0] - pos[snk][0])
        dy = abs(pos[drv][1] - pos[snk][1])
        pairs.append((dx + dy, dx, dy, drv, snk))

print("\n=== flop -> flop direct connections (no logic between) ===")
print("  pairs measured: %d" % len(pairs))
if not pairs:
    sys.exit("  none found -- port naming may differ in this netlist")

pairs.sort(reverse=True)
buckets = Counter()
for man, dx, dy, _, _ in pairs:
    if man <= 4:
        buckets["  <=4"] += 1
    elif man <= 16:
        buckets["  5-16"] += 1
    elif man <= 48:
        buckets[" 17-48"] += 1
    elif man <= 128:
        buckets["49-128"] += 1
    else:
        buckets["  >128"] += 1
for k in ("  <=4", "  5-16", " 17-48", "49-128", "  >128"):
    n = buckets[k]
    print("    manhattan %s : %6d  (%.1f%%)" % (k, n, 100.0 * n / len(pairs)))

print("\n  worst 10 by manhattan distance:")
for man, dx, dy, drv, snk in pairs[:10]:
    print("    %4d (dx %3d dy %3d)  %s" % (man, dx, dy, str(hdl(drv))[:80]))

# Which RTL scopes own the long connections? That names the structure.
print("\n  RTL scopes owning connections with manhattan > 48:")
scope = Counter()
for man, dx, dy, drv, snk in pairs:
    if man > 48:
        h = str(hdl(drv))
        scope[h[:90]] += 1
for s, n in scope.most_common(8):
    print("    %6d  %s" % (n, s))
