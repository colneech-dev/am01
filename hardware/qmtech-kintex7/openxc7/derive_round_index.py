#!/usr/bin/env python3
"""
Recover a per-cell ROUND INDEX for the anonymous cells in the synthesised netlist.

WHY THIS MATTERS
----------------
Measured cell-name census of the shipped netlist:

    $abc$...parse_blif$N        41809     anonymous (all LUTs, all MUXF7)
    $auto$ff.cc:337:slice$N     27614     anonymous (all FDREs)
    hierarchical                  423     420 RAMB18 + BUFG/MMCM/IBUF

So floorplan_stripe.py can address 420 of 69869 cells -- 0.6% of the design. Every
floorplan tried this session (striped 102.15 MHz, Y-band 92.36 MHz) was a
rearrangement of that same 0.6%, which is why placement tuning kept refuting.

It matters because the measured critical path is not BRAM-limited. Comparing the
same arc in both tools:

    Vivado  RAMB18E1 2.080 -> net(fo=7) 3.146 -> LUT6 -> net 0.641 -> LUT2 -> FDRE
    ours    RAMB18   2.1   -> net       6.9   -> LUT6 -> net 1.3   -> LUT6 -> FDRE

Identical structure; the whole gap is one net, 3.146 ns vs 6.9 ns. That net ends at
a LUT placed at tile (113,251) while its BRAM sits at (19,5). The misplaced cell is
a LUT, and no floorplan could reach it because it has no name.

CELL names are anonymous, but NET names are not -- 7770 netnames carry roundN,
covering all 21 rounds. This recovers each cell's round from the nets it touches.

    $\\odocrypt_gpio_wrapper_inst.g_miner[0]....crypt.crypter.round0.sboxes.
        sbox0inst.mem$rdreg[0]$d

OUTPUT-FIRST
------------
A cell's round is taken from its OUTPUT net where possible: the output net names
what the cell computes, whereas an input net may come from the previous round and
would pull the cell backwards. Inputs are a fallback only.

USAGE
    ./derive_round_index.py design.json [--emit rounds.json]
"""
import json
import re
import sys
from collections import Counter, defaultdict

ROUND_RE = re.compile(r"round(\d+)")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    emit = None
    if "--emit" in sys.argv:
        emit = sys.argv[sys.argv.index("--emit") + 1]

    d = json.load(open(path))
    mods = d["modules"]
    top = next((m for m in mods if mods[m].get("attributes", {}).get("top")), list(mods)[0])
    mod = mods[top]
    cells = mod["cells"]

    # bit -> round, from the named nets.
    #
    # Collect the SET of rounds each bit is named with, then keep only the bits
    # that name exactly one. A bit named with several rounds is a global signal
    # threaded through every round's hierarchy, not a round-local one, and it
    # carries no placement information.
    #
    # This is not hypothetical. An earlier version broke ties by keeping the
    # lowest round, and exactly ONE bit in this design is named with all 21
    # rounds -- enough to sweep 8786 cells into round 0, inflating it to 11214
    # against a true ~2427. Constraining those to round 0's region would have
    # dragged unrelated logic across the die and quietly poisoned the floorplan.
    bit_rounds = defaultdict(set)
    for name, net in mod["netnames"].items():
        mo = ROUND_RE.search(name)
        if not mo:
            continue
        r = int(mo.group(1))
        for b in net["bits"]:
            if isinstance(b, int):
                bit_rounds[b].add(r)

    ambiguous = sum(1 for rs in bit_rounds.values() if len(rs) > 1)
    bit_round = {b: next(iter(rs)) for b, rs in bit_rounds.items() if len(rs) == 1}
    print("named bits carrying a round index: %d" % len(bit_round))
    print("  discarded as multi-round (global): %d" % ambiguous)

    assigned = {}
    how = Counter()
    per_type = defaultdict(lambda: [0, 0])  # [assigned, total]

    for cname, cell in cells.items():
        ctype = cell["type"]
        per_type[ctype][1] += 1
        dirs = cell.get("port_directions", {})
        conns = cell.get("connections", {})

        # Output first -- an input net may belong to the previous round.
        r = None
        for port, bits in conns.items():
            if dirs.get(port) != "output":
                continue
            for b in bits:
                if isinstance(b, int) and b in bit_round:
                    r = bit_round[b]
                    break
            if r is not None:
                break
        if r is not None:
            how["output net"] += 1
        else:
            for port, bits in conns.items():
                if dirs.get(port) == "output":
                    continue
                for b in bits:
                    if isinstance(b, int) and b in bit_round:
                        r = bit_round[b]
                        break
                if r is not None:
                    break
            if r is not None:
                how["input net (fallback)"] += 1

        if r is None:
            how["UNRESOLVED"] += 1
            continue
        assigned[cname] = r
        per_type[ctype][0] += 1

    total = len(cells)
    print("\nresolved %d / %d cells (%.1f%%)" % (len(assigned), total, 100.0 * len(assigned) / total))
    for k, v in how.most_common():
        print("   %-24s %d" % (k, v))

    print("\nby cell type:")
    for ctype, (a, t) in sorted(per_type.items(), key=lambda kv: -kv[1][1]):
        if t < 50:
            continue
        print("   %-14s %6d / %6d  (%5.1f%%)" % (ctype, a, t, 100.0 * a / t))

    print("\ncells per round:")
    hist = Counter(assigned.values())
    for r in sorted(hist):
        print("   round %-3d %6d" % (r, hist[r]))

    if emit:
        json.dump(assigned, open(emit, "w"))
        print("\nwrote %d cell->round entries to %s" % (len(assigned), emit))


if __name__ == "__main__":
    main()
