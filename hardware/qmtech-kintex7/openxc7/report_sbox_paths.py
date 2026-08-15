#!/usr/bin/env python3
#  AtomMiner AM01 -- QMTECH Kintex-7 + Raspberry Pi CM4 variant
#  Copyright 2015-2022 AtomMiner <atom@atomminer.com>
#
# This code is free software; you can redistribute it and/or modify it
# under the terms of the BSD 3-Clause License as published by the Free
# Software Foundation; See COPYING for more details.
#
"""Is the hash core routing-bound on the S-box address path?

WHY
---
``encrypt_4apply_pbox0`` is 640 plain ``assign out[j] = in[i];`` statements:
the S-box address is a pure permutation of ``state[i]``, a flip-flop output,
at ZERO logic levels.  Yet ``hdl/sbox_large_mux2.v`` measures that address
settling ~9.6 ns into an 11.78 ns ``clk_h`` period -- 82% of the clock on a
path with no logic in it.  If that is right, Fmax is set by placement, and
there is no floorplanning anywhere in this build to fix it.

This measures it, per unrolled encrypt round:

  * where that round's block RAMs were placed (bounding box, RAMB18 grid)
  * where the flip-flops driving their address pins were placed (SLICE grid)
  * the spread (half-perimeter) of that driver set

Spread needs no timing model, which matters here: nextpnr's STA had to be
patched to time block RAM paths at all (see README.md), so a delay-based
metric is only as good as that patch.  Spread is what a floorplan shrinks,
and it is directly comparable before and after one.

Block RAM bels live on ``RAMB18_X*Y*`` and flip-flops on ``SLICE_X*Y*``.
Those are DIFFERENT site grids -- a RAMB36 tile spans several CLB rows --
so this deliberately does not compute a driver->BRAM distance.  Comparing
the two boxes against each other would be meaningless; compare the spread
against itself, before and after a floorplan.

WHY THIS AND NOT VIVADO
-----------------------
The XC7K325T is not covered by any free Vivado tier (README.md), so a
Tcl-based report is unusable for most people working on this board.  This
reads the post-route JSON that ``nextpnr-xilinx --write`` already emits, with
nothing but the standard library -- no Vivado, and no nextpnr Python
bindings either.

USAGE
-----
    ./build.sh am01_qmtech_top out <sources...>      # emits out/<top>.routed.json
    ./report_sbox_paths.py out/am01_qmtech_top.routed.json

If your build predates the ``--write`` flag in build.sh, add it by hand:

    nextpnr-xilinx ... --write out/top.routed.json

Self-test (no nextpnr needed, checks the parser against a synthetic design):

    ./report_sbox_paths.py --selftest
"""

import json
import re
import sys
from collections import defaultdict

# Bel strings look like "RAMB18_X4Y30/RAMB18E1_L" or "SLICE_X12Y88/AFF".
_XY = re.compile(r"X(\d+)Y(\d+)")
# After `synth_xilinx -flatten` (build.sh's default) the hierarchy survives in
# the cell name, so the round index is recoverable from the path itself.
_ROUND = re.compile(r"round(\d+)")
_BRAM = re.compile(r"^RAMB(18|36)")
_FF = re.compile(r"^FD[RSCP]?E?$")


def bel_xy(bel):
    m = _XY.search(bel or "")
    return (int(m.group(1)), int(m.group(2))) if m else None


def bbox(points):
    """-> (xmin, xmax, ymin, ymax, n) or None."""
    pts = [p for p in points if p]
    if not pts:
        return None
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return (min(xs), max(xs), min(ys), max(ys), len(pts))


def load_cells(path):
    """-> {cell_name: {"type":..., "xy":..., "conns":..., "dirs":...}}"""
    with open(path) as fh:
        design = json.load(fh)
    modules = design.get("modules") or {}
    if not modules:
        raise SystemExit(f"{path}: no 'modules' -- is this a nextpnr/yosys JSON?")
    # nextpnr writes a single top module; if several, take the largest.
    mod = max(modules.values(), key=lambda m: len(m.get("cells") or {}))
    out = {}
    for name, cell in (mod.get("cells") or {}).items():
        attrs = cell.get("attributes") or {}
        bel = attrs.get("NEXTPNR_BEL") or attrs.get("BEL") or ""
        out[name] = {
            "type": cell.get("type", ""),
            "xy": bel_xy(bel),
            "conns": cell.get("connections") or {},
            "dirs": cell.get("port_directions") or {},
        }
    return out


def driver_index(cells):
    """net bit -> driving cell name."""
    drv = {}
    for name, c in cells.items():
        for port, bits in c["conns"].items():
            if c["dirs"].get(port) != "output":
                continue
            for b in bits:
                if isinstance(b, int):
                    drv[b] = name
    return drv


def analyse(cells):
    """-> {round_index: {"bram": [...], "drv": [...], "unplaced": n}}

    NOTE: block RAM bels live on the RAMB18_X*Y* site grid and flip-flops on
    SLICE_X*Y*.  Those are different coordinate systems -- a RAMB36 tile spans
    several CLB rows -- so a driver->BRAM distance mixing them is meaningless
    and is deliberately NOT computed.  What is reported instead is the spread
    of each set within its own grid, which is exactly what a floorplan shrinks
    and is directly comparable before and after one.
    """
    drv = driver_index(cells)
    rounds = defaultdict(lambda: {"bram": [], "drv": [], "unplaced": 0})

    for name, c in cells.items():
        if not _BRAM.match(c["type"]):
            continue
        m = _ROUND.search(name)
        key = int(m.group(1)) if m else -1
        r = rounds[key]

        if c["xy"] is None:
            r["unplaced"] += 1
            continue
        r["bram"].append(c["xy"])

        for port, bits in c["conns"].items():
            if not port.upper().startswith("ADDR"):
                continue
            for b in bits:
                if not isinstance(b, int):
                    continue
                src = drv.get(b)
                if src is None or src not in cells:
                    continue
                sxy = cells[src]["xy"]
                if sxy is None:
                    continue
                r["drv"].append(sxy)
    return rounds


def spread(bb):
    """Half-perimeter of a bounding box, in that box's own site grid."""
    return 0 if not bb else (bb[1] - bb[0]) + (bb[3] - bb[2])


def fmt(bb):
    if not bb:
        return "n/a"
    return f"{bb[0]}-{bb[1]}, {bb[2]}-{bb[3]} ({bb[4]})"


def report(rounds, out=sys.stdout):
    print("", file=out)
    print("=" * 78, file=out)
    print(" S-box address path -- placement spread per unrolled encrypt round", file=out)
    print("=" * 78, file=out)
    print(f"  {'round':<7}{'BRAM bbox [RAMB18 grid]':<26}"
          f"{'addr driver bbox [SLICE grid]':<32}{'drv spread':>11}", file=out)
    print("  " + "-" * 76, file=out)

    worst = 0
    for key in sorted(rounds):
        r = rounds[key]
        label = str(key) if key >= 0 else "(none)"
        sp = spread(bbox(r["drv"]))
        print(f"  {label:<7}{fmt(bbox(r['bram'])):<26}{fmt(bbox(r['drv'])):<32}"
              f"{sp:>11}", file=out)
        worst = max(worst, sp)
        if r["unplaced"]:
            print(f"          ({r['unplaced']} block RAM(s) with no NEXTPNR_BEL "
                  f"-- is this JSON post-placement?)", file=out)

    print("", file=out)
    if not rounds:
        print("  No block RAMs found. Check the JSON is a placed nextpnr design.", file=out)
        return worst
    if -1 in rounds and len(rounds) == 1:
        print("  No round<N> in any cell name. If you built with FLATTEN=0 the", file=out)
        print("  hierarchy is in modules rather than names; rebuild with the", file=out)
        print("  default FLATTEN=1 for a per-round breakdown.", file=out)
    print(f"  Worst address-driver spread: {worst} slice rows+cols "
          f"(half-perimeter)", file=out)
    print("", file=out)
    print("  BRAM and SLICE are separate site grids, so no driver->BRAM distance", file=out)
    print("  is computed -- compare the spread against itself before and after a", file=out)
    print("  floorplan, not against the BRAM box.", file=out)
    print("", file=out)
    print("  Interpretation:", file=out)
    print("    Wide driver spread -> the 640 flip-flops feeding one round's", file=out)
    print("       address pins are scattered. Floorplan the round (its block RAMs", file=out)
    print("       and those flops) and re-measure both spread and clk_h.", file=out)
    print("    Tight spread but a slow clock -> not placement. Look at block RAM", file=out)
    print("       setup time and the fabric instead.", file=out)
    print("", file=out)
    return worst


def selftest():
    """Synthetic 2-round design: round0 placed tight, round1 deliberately far."""
    cells = {}
    # round0: BRAM at (11,10); ff_a (10,10) is 1 away, ff_b (10,11) is 2.
    cells["top.crypter.round0.sboxes.s0"] = {
        "type": "RAMB18E1", "xy": (11, 10),
        "conns": {"ADDRARDADDR": [100, 101]}, "dirs": {"ADDRARDADDR": "input"}}
    cells["top.crypter.round0.ff_a"] = {
        "type": "FDRE", "xy": (10, 10), "conns": {"Q": [100]}, "dirs": {"Q": "output"}}
    cells["top.crypter.round0.ff_b"] = {
        "type": "FDRE", "xy": (10, 11), "conns": {"Q": [101]}, "dirs": {"Q": "output"}}
    # round1: FF at (60,80) -> BRAM at (11,12).  distance 49+68 = 117
    cells["top.crypter.round1.sboxes.s0"] = {
        "type": "RAMB18E1", "xy": (11, 12),
        "conns": {"ADDRARDADDR": [200]}, "dirs": {"ADDRARDADDR": "input"}}
    cells["top.crypter.round1.ff_a"] = {
        "type": "FDRE", "xy": (60, 80), "conns": {"Q": [200]}, "dirs": {"Q": "output"}}

    rounds = analyse(cells)
    ok = True

    def check(label, got, want):
        nonlocal ok
        status = "ok" if got == want else "FAIL"
        if got != want:
            ok = False
        print(f"  {label:<44} got {got!r:<14} want {want!r:<14} {status}")

    print("self-test: synthetic 2-round design")
    check("rounds discovered", sorted(rounds), [0, 1])
    check("round0 driver spread", spread(bbox(rounds[0]["drv"])), 1)
    check("round1 driver spread", spread(bbox(rounds[1]["drv"])), 0)
    check("no cross-grid distance key", "dist" in rounds[0], False)
    check("round0 BRAM bbox", bbox(rounds[0]["bram"]), (11, 11, 10, 10, 1))
    check("round0 driver bbox", bbox(rounds[0]["drv"]), (10, 10, 10, 11, 2))
    check("unplaced counted", rounds[0]["unplaced"], 0)

    # an unplaced BRAM must be reported, not silently dropped
    cells["top.crypter.round0.sboxes.s1"] = {
        "type": "RAMB18E1", "xy": None, "conns": {}, "dirs": {}}
    check("unplaced BRAM detected", analyse(cells)[0]["unplaced"], 1)
    check("spread of empty box", spread(None), 0)

    report(analyse(cells), out=open("/dev/null", "w"))
    print("  report() rendered without error                     ok")
    print("\nself-test:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main(argv):
    if len(argv) != 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0 if len(argv) == 2 else 2
    if argv[1] == "--selftest":
        return selftest()
    report(analyse(load_cells(argv[1])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
