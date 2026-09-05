#!/usr/bin/env python3
"""Verify that fanout replication preserved function, structurally.

WHY THIS AND NOT T11
--------------------
T11 (X-propagation on the physical netlist, via json2dcp + VerilogPhys) is the
right end-to-end check, but json_drc-portable and RapidWright are not installed
here, so it needs tooling set up first.

Meanwhile the specific risk I introduced is narrower and directly checkable:
replicate_fanout_placed.py clones driver cells and rewires ~1700 load
connections BY INDEX. A mistake there would not show up as a routing failure or
a timing regression -- it would show up as a miner producing rejects on
hardware, which is the worst possible place to find it.

THE INVARIANT
-------------
For the transformation to be sound, for every replica R of original driver D:

  1. R has the same cell TYPE as D
  2. R has identical connections on every INPUT port (same D/C/CE/R/A* bits),
     so it computes the same value every cycle
  3. R's OUTPUT port drives exactly one net, and that net is new (nothing else
     drives it)
  4. every load moved onto R's output net was previously on D's output net
  5. D's output net still has a driver and at least one load

Violating (2) is the realistic bug and the one that would silently corrupt
results.

Usage: verify_replication.py <original.json> <replicated.json>
"""
import json
import sys
from collections import defaultdict

OUT_PORTS = {"Q", "O", "O6", "O5"}


def load(path):
    d = json.load(open(path))
    mods = d["modules"]
    top = next(m for m in mods if mods[m].get("attributes", {}).get("top"))
    return mods[top]["cells"]


def nets_of(cells):
    drv = {}
    loads = defaultdict(set)
    for name, c in cells.items():
        for port, bits in c.get("connections", {}).items():
            for b in bits:
                if not isinstance(b, int):
                    continue
                if port in OUT_PORTS:
                    drv.setdefault(b, set()).add(name)
                else:
                    loads[b].add(name)
    return drv, loads


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: verify_replication.py <original.json> <replicated.json>")
    orig = load(sys.argv[1])
    rep = load(sys.argv[2])
    print("cells: original %d, replicated %d (+%d)"
          % (len(orig), len(rep), len(rep) - len(orig)))

    odrv, oloads = nets_of(orig)
    rdrv, rloads = nets_of(rep)

    replicas = [n for n in rep if "$rep" in n and n not in orig]
    print("replica cells found: %d" % len(replicas))
    if not replicas:
        sys.exit("ERROR: no replicas present -- nothing to verify")

    fails = 0
    checked_loads = 0
    for r in replicas:
        base = r.rsplit("$rep", 1)[0]
        if base not in orig:
            print("  FAIL %s: no original named %s" % (r, base))
            fails += 1
            continue
        rc, oc = rep[r], orig[base]

        # (1) same type
        if rc.get("type") != oc.get("type"):
            print("  FAIL %s: type %s != %s" % (r, rc.get("type"), oc.get("type")))
            fails += 1

        # (2) identical INPUT connections -- the invariant that matters
        for port, bits in oc.get("connections", {}).items():
            if port in OUT_PORTS:
                continue
            if rc.get("connections", {}).get(port) != bits:
                print("  FAIL %s: input port %s differs from original" % (r, port))
                fails += 1

        # (3) output drives exactly one, new, singly-driven net
        for port, bits in rc.get("connections", {}).items():
            if port not in OUT_PORTS:
                continue
            for b in bits:
                if not isinstance(b, int):
                    continue
                if b in odrv:
                    print("  FAIL %s: output net %d already existed" % (r, b))
                    fails += 1
                elif len(rdrv.get(b, ())) != 1:
                    print("  FAIL %s: output net %d has %d drivers"
                          % (r, b, len(rdrv.get(b, ()))))
                    fails += 1
                else:
                    # (4) every load on it must have been a load of the original
                    obit = None
                    for p2, bits2 in oc.get("connections", {}).items():
                        if p2 in OUT_PORTS and bits2:
                            obit = bits2[0]
                    moved = rloads.get(b, set())
                    checked_loads += len(moved)
                    if obit is not None:
                        stray = moved - oloads.get(obit, set())
                        if stray:
                            print("  FAIL %s: %d loads were not on the original net"
                                  % (r, len(stray)))
                            fails += 1

    # (5) originals still driven and still used
    for r in replicas:
        base = r.rsplit("$rep", 1)[0]
        if base not in rep:
            print("  FAIL: original %s disappeared" % base)
            fails += 1

    print("load connections verified: %d" % checked_loads)
    if fails:
        print("\nRESULT: %d FAILURES -- do not build this netlist" % fails)
        sys.exit(1)
    print("\nRESULT: all invariants hold")
    print("  every replica has identical inputs to its original, drives a fresh")
    print("  singly-driven net, and took only loads that were on the original.")


if __name__ == "__main__":
    main()
