#!/usr/bin/env python3
"""
Give EVERY cell a durable placement group, derived from hierarchical net names.

WHY NOT JUST ROUND INDEX
------------------------
derive_round_index.py resolves 51621 of 71632 cells by matching round(\\d+) in net
names. The other 18354 are not badly-parsed round logic -- sampling shows they are
a different part of the design entirely:

    LUT2   odocrypt_gpio_wrapper_inst.req_sync2_h
    LUT3   odocrypt_gpio_wrapper_inst.addr_latched
    LUT6   odocrypt_gpio_wrapper_inst.hash_active_bus
    LUT5   $auto$alumacc.cc:512:replace_alu$58344.Y      (the nonce adder)

GPIO wrapper, control, and the adder. Forcing them into a round region would be
wrong, and neighbour propagation would have done exactly that for 52% of them --
a comparator reading round 20's output is not round-20 logic. So the goal is not
"more rounds", it is a group for every cell: rounds get theirs, the wrapper gets
its own, the adder gets its own.

WHY NOT USE VIVADO'S PLACEMENT INSTEAD
--------------------------------------
Vivado gives an exact site for all 70011 cells, but keyed on yosys cell names, and
those are pure counters:

    $abc$493613$auto$blifparse.cc:557:parse_blif$493614

tools_name_churn_test.sh measures what that costs. Two modules identical except
for one extra unrelated gate: 15 cells vs 17, and ZERO names in common -- the ABC
counter moved 1611 -> 1613 and renamed everything, including cells whose logic was
untouched. A map keyed on those names is a snapshot of one netlist, useless for
the next build.

RTL hierarchy does not churn. 'crypter.round14.sboxes.sbox35inst' comes from the
source, verified identical across files at 1260/1260 sbox paths. That is what this
keys on, which is what makes the result reusable.

HOW
---
A yosys net name is a dotted path whose components are either RTL identifiers
('crypter', 'round14', 'sbox35inst', 'g_miner[0]') or generated fragments carrying
a counter ('$auto$alumacc.cc:512:replace_alu$58344', '$abc$493613$...').

For each cell: collect the net names it touches, keep only the DURABLE leading
identifier components, and take the deepest such path. Truncate to --depth to
control granularity. Cells with no hierarchical net at all fall back to a
counter-stripped generated name, which still groups all cells of one yosys pass
together and is stable as long as the pass and source line are.

USAGE
    ./derive_cell_groups.py design.json [--depth 7] [--emit groups.json]
"""
import json
import re
import sys
from collections import Counter, defaultdict

# A generated fragment: anything containing '$'. Everything else is RTL-derived.
GENERATED = re.compile(r"\$")
# Strip trailing counters so a generated group is stable across renumbering.
COUNTER = re.compile(r"\$\d+")


def durable_scope(netname):
    """Longest leading run of RTL identifier components, as a list."""
    parts = netname.split(".")
    out = []
    for p in parts:
        if not p or GENERATED.search(p):
            break
        out.append(p)
    return out


def generated_group(netname):
    """Fallback label for a net with no RTL hierarchy: pass name, counters removed."""
    base = COUNTER.sub("", netname)
    base = base.split(".")[0]
    return base[:60] if base else None


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    depth = int(sys.argv[sys.argv.index("--depth") + 1]) if "--depth" in sys.argv else 7
    emit = sys.argv[sys.argv.index("--emit") + 1] if "--emit" in sys.argv else None

    d = json.load(open(path))
    mods = d["modules"]
    top = next((m for m in mods if mods[m].get("attributes", {}).get("top")), list(mods)[0])
    mod = mods[top]

    # bit -> best scope seen for it, and bit -> fallback label.
    bit_scope = {}
    bit_fallback = {}
    for name, net in mod["netnames"].items():
        sc = durable_scope(name)
        fb = generated_group(name) if not sc else None
        for b in net["bits"]:
            if not isinstance(b, int):
                continue
            if sc:
                # Deepest wins: the most specific scope is the most useful.
                if b not in bit_scope or len(sc) > len(bit_scope[b]):
                    bit_scope[b] = sc
            elif fb and b not in bit_fallback:
                bit_fallback[b] = fb

    print("bits with RTL hierarchy : %d" % len(bit_scope))
    print("bits with only generated names: %d" % len(bit_fallback))

    cells = mod["cells"]
    assigned = {}
    how = Counter()
    per_type = defaultdict(lambda: [0, 0])

    for cname, cell in cells.items():
        ctype = cell["type"]
        if ctype == "$scopeinfo":
            continue
        per_type[ctype][1] += 1
        dirs = cell.get("port_directions", {})
        conns = cell.get("connections", {})

        def scan(want_output):
            best = None
            for port, bits in conns.items():
                is_out = dirs.get(port) == "output"
                if is_out != want_output:
                    continue
                for b in bits:
                    if isinstance(b, int) and b in bit_scope:
                        sc = bit_scope[b]
                        if best is None or len(sc) > len(best):
                            best = sc
            return best

        # Output first: the output net names what the cell computes, whereas an
        # input may belong to the previous stage and would pull it backwards.
        sc = scan(True) or scan(False)
        if sc:
            group = ".".join(sc[:depth])
            how["RTL hierarchy"] += 1
        else:
            fb = None
            for port, bits in conns.items():
                for b in bits:
                    if isinstance(b, int) and b in bit_fallback:
                        fb = bit_fallback[b]
                        break
                if fb:
                    break
            if fb:
                group = fb
                how["generated (counter-stripped)"] += 1
            else:
                how["UNRESOLVED"] += 1
                continue
        assigned[cname] = group
        per_type[ctype][0] += 1

    total = sum(t for _, t in per_type.values())
    print("\nresolved %d / %d cells (%.2f%%)" % (len(assigned), total, 100.0 * len(assigned) / total))
    for k, v in how.most_common():
        print("   %-32s %d" % (k, v))

    print("\nby cell type:")
    for ctype, (a, t) in sorted(per_type.items(), key=lambda kv: -kv[1][1]):
        if t < 50:
            continue
        flag = "" if a == t else "   <-- incomplete"
        print("   %-12s %6d / %6d  (%6.2f%%)%s" % (ctype, a, t, 100.0 * a / t, flag))

    hist = Counter(assigned.values())
    print("\n%d distinct groups; largest:" % len(hist))
    for g, n in hist.most_common(12):
        print("   %-58s %6d" % (g[-58:], n))

    if emit:
        json.dump(assigned, open(emit, "w"))
        print("\nwrote %d cell->group entries to %s" % (len(assigned), emit))


if __name__ == "__main__":
    main()
