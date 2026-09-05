#!/usr/bin/env python3
"""Verify the claim that Vivado packs BRAMs tighter than nextpnr does.

The BRAM-egress review concluded the gap is a TOOL limit and specifically a
placement-in-X limit: Vivado confines each encryption round's BRAMs to a few
ADJACENT columns, while nextpnr smears every round across the whole die width.

That is the most actionable claim of the session, and two prior reviews
overturned conclusions I had already committed, so it gets checked rather than
believed. Both placements are on disk for the SAME netlist.

Reads:
  vivado_placement.txt                     Vivado's placement
  out_nm1_nosr/nextpnr_placement.xdc       nextpnr's, as Vivado constraints
"""
import re
import sys
from collections import defaultdict

BASE = "/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7/"

# RAMB18_X<c>Y<r>  -> column index c, row r
site_re = re.compile(r"RAMB18_X(\d+)Y(\d+)")
# round number from the hierarchical cell name
# vivado_placement.txt uses '.' separators; nextpnr_placement.xdc uses '/'.
round_re = re.compile(r"crypter[./]round(\d+)[./]")


def load(path, name_first):
    """Return {cellname: (col,row)} for RAMB18 placements."""
    out = {}
    try:
        fh = open(path, errors="replace")
    except OSError as e:
        print("  cannot open %s: %s" % (path, e))
        return out
    with fh:
        for line in fh:
            m = site_re.search(line)
            if not m:
                continue
            col, row = int(m.group(1)), int(m.group(2))
            # cell name: whatever token carries the round hierarchy
            rm = round_re.search(line)
            if not rm:
                continue
            key = line.strip()
            out[key] = (col, row, int(rm.group(1)))
    return out


def summarise(tag, placements):
    if not placements:
        print("  %s: no RAMB18 placements parsed" % tag)
        return
    tiles = defaultdict(int)          # (col,row) -> bels used
    per_round = defaultdict(list)     # round -> [(col,row)]
    for _, (c, r, rnd) in placements.items():
        tiles[(c, r)] += 1
        per_round[rnd].append((c, r))

    both = sum(1 for v in tiles.values() if v >= 2)
    cols = sorted({c for c, _ in tiles})
    rows = sorted({r for _, r in tiles})

    spans_x, spans_y, ncols = [], [], []
    for rnd, locs in per_round.items():
        cs = [c for c, _ in locs]
        rs = [r for _, r in locs]
        spans_x.append(max(cs) - min(cs))
        spans_y.append(max(rs) - min(rs))
        ncols.append(len({c for c in cs}))

    print("  %s" % tag)
    print("    RAMB18 placed        : %d" % len(placements))
    print("    BRAM tiles occupied  : %d" % len(tiles))
    print("    tiles with BOTH bels : %d" % both)
    print("    column indices used  : %s" % cols)
    print("    row range            : %d..%d" % (rows[0], rows[-1]))
    if spans_x:
        print("    per-round column span: mean %.1f  max %d" %
              (sum(spans_x) / len(spans_x), max(spans_x)))
        print("    per-round row span   : mean %.1f" % (sum(spans_y) / len(spans_y)))
        print("    distinct cols/round  : mean %.1f  max %d" %
              (sum(ncols) / len(ncols), max(ncols)))


print("=== Vivado ===")
summarise("vivado_placement.txt", load(BASE + "vivado_placement.txt", True))
print()
print("=== nextpnr ===")
summarise("nextpnr_placement.xdc",
          load(BASE + "out_nm1_nosr/nextpnr_placement.xdc", False))
