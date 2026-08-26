#!/usr/bin/env python3
"""
Floorplan the OdoCrypt sbox BRAMs by writing BEL attributes into the yosys JSON.

WHY
---
nextpnr's HeAP placer has no congestion model and bets everything on one
quadratic solve landing in a good local optimum. Measured on this design, the
RNG seed alone swings final placement quality by 13% -- and because the design
sits on a routability cliff (6% worse wirelength -> 80x more unrouted arcs),
that is the difference between 17 unrouted arcs and 2464:

    seed  7   legal wirelen 4,377,084   ->   17 unrouted
    seed 11   legal wirelen 4,614,154   -> 1394 unrouted
    seed  3   legal wirelen 4,945,397   -> 2464 unrouted

Vivado does not have this problem because it FLOORPLANS: multi-phase placement
with congestion feedback and explicit region assignment, rather than one
analytical solve.

The structural reason this design punishes HeAP: OdoCrypt is 21 rounds x 20
sboxes with a PERMUTATION between rounds, so every round-N+1 LUT reads bits from
many scattered round-N BRAMs. The quadratic objective pulls each LUT to its
drivers' centroid; when the drivers are scattered chip-wide, all the centroids
collapse toward the middle. That is the measured hotspot -- SLICE_X9Y164 needing
inputs from four different BRAMs on a device that is 10% occupied.

WHAT THIS DOES
--------------
Pins each round's 20 BRAMs to a contiguous block of RAMB18 sites, so the
downstream LUT centroids become LOCAL and TIGHT instead of chip-wide averages.
placer_heap.cc:378 place_constraints() honours a `BEL` attribute and binds at
STRENGTH_USER before the analytical solve runs, so the solve places logic around
fixed anchors rather than choosing the anchors itself.

Side benefit: the result becomes deterministic -- no more 17-vs-2464 lottery.

GEOMETRY (derived from the v26 FASM, see below)
-----------------------------------------------
7 BRAM columns exist: tile X = 6, 17, 32, 62, 74, 80, 89, mapping to RAMB18 site
columns X0..X6 in that order. Full columns span tile Y 0..345 in steps of 5 = 70
tiles, 2 RAMB18 sites per tile = 140 sites per column.

21 rounds x 20 BRAMs = 420 = exactly 3 full columns. We use the three leftmost
columns (X0, X1, X2) because they are physically closest together, which keeps
the round-to-round hops short.

Rounds are laid out SERPENTINE: up column X0, down X1, up X2. Consecutive rounds
therefore stay adjacent even across a column change, which matters because
round N's BRAM outputs feed round N+1's logic.

CAVEATS
-------
* The site grid is inferred from which tiles v26 actually used, not from the
  chipdb. If a column is shorter than 70 tiles, nextpnr will fail loudly with
  "No Bel named ..." -- a clear error, not silent corruption. Adjust and re-run.
* Pinned BRAM tiles become all-STRENGTH_USER, which triggers the frozen-tile
  validity bypass at arch_place.cc:336. For BRAM tiles that is likely harmless
  (no LUT packing or control-set rules apply), but it is a real interaction.
* This is a floorplan HEURISTIC, not a proof. It could be worse than the
  placer's own choice -- though seed 3's 2464 is a low bar to clear.

USAGE
-----
    ./floorplan_brams.py in.json out.json [--columns 0,1,2] [--dry-run]
"""
import argparse
import json
import re
import sys
from collections import defaultdict

SITES_PER_TILE = 2
TILES_PER_COL = 70          # tile Y 0..345 step 5
SITES_PER_COL = TILES_PER_COL * SITES_PER_TILE   # 140


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("infile")
    ap.add_argument("outfile", nargs="?")
    ap.add_argument("--columns", default="0,1,2,3,4,5,6",
                    help="RAMB18 site columns to use, left to right (default 0,1,2)")
    ap.add_argument("--cols-per-round", type=int, default=3,
                    help="vivado mode: adjacent columns per round (measured: Vivado uses ~3)")
    ap.add_argument("--mode", choices=["block", "stripe", "vivado"], default="stripe",
                    help="block = each round packed into one column (MEASURED WORSE, "
                         "see comment in source). stripe = each round spread across "
                         "all columns, distributing BRAM egress demand.")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    cols = [int(c) for c in args.columns.split(",")]

    with open(args.infile) as f:
        design = json.load(f)

    mods = design["modules"]
    top = next((m for m in mods if mods[m].get("attributes", {}).get("top")), list(mods)[0])
    cells = mods[top]["cells"]

    # Group BRAMs by round, and sort within a round by sbox instance number so
    # the assignment is stable and independent of dict ordering.
    by_round = defaultdict(list)
    for name, cell in cells.items():
        if "RAMB" not in cell["type"]:
            continue
        m = re.search(r"round(\d+)\.", name)
        if not m:
            print(f"WARNING: BRAM with no round in name, skipping: {name}", file=sys.stderr)
            continue
        sb = re.search(r"sbox(\d+)inst", name)
        by_round[int(m.group(1))].append((int(sb.group(1)) if sb else 0, name))

    rounds = sorted(by_round)
    total = sum(len(v) for v in by_round.values())
    print(f"{total} BRAMs across {len(rounds)} rounds "
          f"({', '.join(str(len(by_round[r])) for r in rounds)} per round)")

    rounds_per_col = SITES_PER_COL // 20        # 7
    need_cols = (len(rounds) + rounds_per_col - 1) // rounds_per_col
    if args.mode == "block" and need_cols > len(cols):
        sys.exit("ERROR: block mode needs %d columns, only %d given" % (need_cols, len(cols)))

    assigned = 0
    if args.mode == "vivado":
        # VIVADO-MEASURED layout: a few ADJACENT columns per round.
        #
        # This is not a guess. Vivado reaches 158.81 MHz on this exact netlist,
        # and verify_bram_spread.py measures both placements in the same
        # coordinate system:
        #
        #   per round          Vivado (158.81)   nextpnr (89.30)
        #   column span        2.2 (max 4)       5.2 (max 6)
        #   distinct columns   3.2 (max 5)       6.1 (max 7)
        #   row span          11.4               6.2
        #   columns used       0..5              0..6
        #   row range         53..137            0..139
        #
        # Both use 420 tiles, one RAMB18 per tile, none double-packed -- so the
        # difference is purely WHERE, not how densely.
        #
        # Vivado confines each round's 20 BRAMs to ~3 adjacent columns; nextpnr
        # smears every round across ~6 of the 7, i.e. the whole die width. BRAM
        # nets are 10.7% of nets but 42.5% of total HPWL, with a median span of
        # 124 tiles against 1 for SLICE nets, so this is where the wirelength is.
        #
        # WHY NEITHER EXISTING MODE
        # -------------------------
        # `stripe` (the current default) spreads each round across ALL columns --
        # precisely maximising what Vivado minimises. `block` packs a round into
        # 10 contiguous tiles, which over-corrects: its failed arcs were 817
        # SLICE->SLICE against just 37 BRAM->SLICE, i.e. it crowded that round's
        # ~3300 LUTs around a 25-row anchor rather than saturating BRAM egress.
        # The target sits between them, and Vivado has already measured it.
        # Per-column allocation cursor.
        #
        # An earlier version computed the Y band as (idx * per_col) % (SITES-...)
        # which WRAPS: with 21 rounds x 7 rows against ~133 usable rows, rounds
        # 19/20 wrapped back onto rounds 0/1 and produced 13 duplicate sites
        # (420 assignments, 407 unique). Cursors cannot collide by construction.
        #
        # NOTE ON COLUMN HEIGHTS: the RAMB18 columns are NOT uniform. On
        # xc7k325t, columns 0-5 run to Y138-139 but column 6 stops at Y59, so
        # SITES_PER_COL=140 is only valid for 0-5. Vivado uses X0..X5 and leaves
        # column 6 alone; pass --columns 0,1,2,3,4,5 to match. Assigning a site
        # that does not exist fails hard:
        #   ERROR: No Bel named 'RAMB18_X6Y63/RAMB18E1' located for this chip
        ncol = len(cols)
        cpr = max(1, min(args.cols_per_round, ncol))
        span = max(1, ncol - cpr + 1)
        cursor = {c: 0 for c in cols}
        for idx, rnd in enumerate(rounds):
            members = sorted(by_round[rnd])
            rc = cols[(idx % span):(idx % span) + cpr]
            lo = {c: cursor[c] for c in rc}
            for j, (_, name) in enumerate(members):
                col = rc[j % cpr]
                site_y = cursor[col]
                cursor[col] += 1
                if site_y >= SITES_PER_COL:
                    sys.exit("ERROR: column %d exhausted at Y%d" % (col, site_y))
                bel = "RAMB18_X%dY%d/RAMB18E1" % (col, site_y)
                if not args.dry_run:
                    cells[name].setdefault("attributes", {})["BEL"] = bel
                assigned += 1
            print("  round %2d -> cols %s  Y%s" %
                  (rnd, ",".join(str(c) for c in rc),
                   ",".join("%d-%d" % (lo[c], cursor[c] - 1) for c in rc)))
        print("assigned %d BEL attributes" % assigned)
        if args.dry_run:
            print("(dry run, nothing written)")
            return
        if not args.outfile:
            sys.exit("ERROR: outfile required unless --dry-run")
        with open(args.outfile, "w") as f:
            json.dump(design, f)
        print("wrote %s" % args.outfile)
        return

    if args.mode == "stripe":
        # STRIPED layout.
        #
        # BLOCK mode (below) was MEASURED WORSE: packing each round's 20 BRAMs
        # into 10 contiguous tiles gave an 18.6% better wirelength (3,545,752 vs
        # 4,358,278) but routing collapsed -- congestion rose at iteration 2 and
        # unrouted arcs hit 717 by iteration 3, where the unfloorplanned run held
        # 0 through iteration 4. Cause: ~200 BRAM output signals all leaving one
        # 10-tile region saturates local egress. Shorter wires, worse routability.
        #
        # Lesson: HPWL is a bad proxy for routability here. The binding constraint
        # is BRAM egress capacity, not wire length.
        #
        # So: spread each round ACROSS all columns at a Y band that advances with
        # the round number. Consecutive rounds stay at similar Y (dataflow stays
        # local) while each round's egress is distributed over every BRAM column.
        ncol = len(cols)
        for idx, rnd in enumerate(rounds):
            members = sorted(by_round[rnd])
            per_col = (len(members) + ncol - 1) // ncol
            band = (idx * per_col) % max(1, SITES_PER_COL - per_col)
            for j, (_, name) in enumerate(members):
                col = cols[j % ncol]
                site_y = band + (j // ncol)
                bel = "RAMB18_X%dY%d/RAMB18E1" % (col, site_y)
                if not args.dry_run:
                    cells[name].setdefault("attributes", {})["BEL"] = bel
                assigned += 1
            print("  round %2d -> Y%d..Y%d across %d cols" % (rnd, band, band + per_col - 1, ncol))
        print("assigned %d BEL attributes" % assigned)
        if args.dry_run:
            print("(dry run, nothing written)")
            return
        if not args.outfile:
            sys.exit("ERROR: outfile required unless --dry-run")
        with open(args.outfile, "w") as f:
            json.dump(design, f)
        print("wrote %s" % args.outfile)
        return

    for idx, rnd in enumerate(rounds):
        col = cols[idx // rounds_per_col]
        slot = idx % rounds_per_col
        # Serpentine: reverse the slot order in every other column so that
        # consecutive rounds stay adjacent across a column change.
        if (idx // rounds_per_col) % 2 == 1:
            slot = rounds_per_col - 1 - slot
        base = slot * 20

        members = sorted(by_round[rnd])
        if len(members) != 20:
            print(f"WARNING: round {rnd} has {len(members)} BRAMs, expected 20", file=sys.stderr)

        for j, (_, name) in enumerate(members):
            site_y = base + j
            bel = f"RAMB18_X{col}Y{site_y}/RAMB18E1"
            if not args.dry_run:
                cells[name].setdefault("attributes", {})["BEL"] = bel
            assigned += 1
        print(f"  round {rnd:2d} -> RAMB18_X{col}Y{base}..Y{base + len(members) - 1}")

    print(f"assigned {assigned} BEL attributes")

    if args.dry_run:
        print("(dry run, nothing written)")
        return
    if not args.outfile:
        sys.exit("ERROR: outfile required unless --dry-run")
    with open(args.outfile, "w") as f:
        json.dump(design, f)
    print(f"wrote {args.outfile}")


if __name__ == "__main__":
    main()
