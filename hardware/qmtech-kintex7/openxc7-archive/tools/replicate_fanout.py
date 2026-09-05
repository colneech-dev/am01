#!/usr/bin/env python3
"""Replicate high-fanout drivers in a yosys JSON netlist.

WHY
---
Measured on the 129.79 MHz placement (measure_fanout_nets.py):

    loads   dx   dy   net
      809   87   75   keccak800 mux select
      643   55   85   crypt.progress[1] mux select
      608   51   76   get_block_pulse_h

A single flip-flop driving 640 loads spread over a 55x85 tile box cannot be
fast, however well it is placed -- the signal has to physically reach all of
them. Splitting the driver into N identical copies, each serving a compact
subset, lets the placer put every copy near its own loads.

The fanout is in the RTL, not a synthesis artefact: encrypt.v:15317-15329 is
`if (read) state[0] <= in; else state[0] <= next[21];` over a 640-bit register,
so one control bit selects 640 state bits. keccak800.v:248-258 is the same
idiom. Neither yosys nor nextpnr has any high-fanout replication pass -- this
was confirmed by enumerating every registered yosys pass. Vivado's
phys_opt_design does it, which is part of why it reaches 158.81 MHz.

WHY A NETLIST PASS RATHER THAN RTL
----------------------------------
encrypt.v is GENERATED per OdoCrypt epoch (every 10 days), so an RTL edit is
lost at the next regeneration unless odo_gen itself is patched. A netlist pass
is epoch-independent and also catches keccak800's instance for free.

PARTITIONING
------------
Loads are split into contiguous chunks in netlist order. That is a proxy for
spatial locality, not a guarantee: at this stage there is no placement to
consult. Adjacent bits of the same wide register usually place near each other,
which is what makes the proxy reasonable. If it proves too weak, the better
input is a placed JSON -- but that requires a two-pass flow.

SAFETY
------
Copies are marked (* keep *) and given distinct names. Without `keep`,
opt_merge would spot N identical flip-flops with identical inputs and merge
them straight back, silently undoing the pass -- yosys's opt_merge skips cells
carrying `keep` (passes/opt/opt_merge.cc).

Usage:
    replicate_fanout.py <in.json> <out.json> [--threshold N] [--per-copy N] [--dry-run]
"""
import argparse
import json
import sys
from collections import defaultdict

# Output ports by cell type. Only these drive nets we may replicate.
OUT_PORTS = {"Q", "O", "O6", "O5"}
# Cell types safe to clone: stateless LUTs, and FFs whose inputs we copy wholesale.
# SRL16E/SRLC32E hold state but are driven purely by their own inputs, so N
# copies with identical connections produce identical outputs -- as safe to
# clone as a flip-flop. The 809-load keccak800 select is driven by an SRL16E.
REPLICABLE = ("FD", "LUT", "SRL")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("infile")
    ap.add_argument("outfile", nargs="?")
    ap.add_argument("--threshold", type=int, default=200,
                    help="replicate drivers with more than this many loads")
    ap.add_argument("--per-copy", type=int, default=100,
                    help="target loads per copy")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    design = json.load(open(args.infile))
    mods = design["modules"]
    top = next(m for m in mods if mods[m].get("attributes", {}).get("top"))
    cells = mods[top]["cells"]
    netnames = mods[top].get("netnames", {})

    # Highest bit id in use, so new nets get fresh ids.
    maxbit = 1
    for c in cells.values():
        for bits in c.get("connections", {}).values():
            for b in bits:
                if isinstance(b, int) and b > maxbit:
                    maxbit = b
    for n in netnames.values():
        for b in n.get("bits", []):
            if isinstance(b, int) and b > maxbit:
                maxbit = b

    # bit -> driver cell, and bit -> [(load cell, port, index)]
    driver = {}
    loads = defaultdict(list)
    for name, c in cells.items():
        for port, bits in c.get("connections", {}).items():
            for i, b in enumerate(bits):
                if not isinstance(b, int):
                    continue
                if port in OUT_PORTS:
                    driver[b] = name
                else:
                    loads[b].append((name, port, i))

    targets = []
    for bit, drv in driver.items():
        n = len(loads.get(bit, ()))
        if n <= args.threshold:
            continue
        ctype = cells[drv].get("type", "")
        if not ctype.startswith(REPLICABLE):
            print("  skip (type %s, %d loads): %s" % (ctype, n, drv[:60]))
            continue
        targets.append((n, bit, drv))
    targets.sort(reverse=True)

    print("drivers above threshold %d: %d" % (args.threshold, len(targets)))
    added = 0
    for n, bit, drv in targets:
        ncopies = max(2, (n + args.per_copy - 1) // args.per_copy)
        src = cells[drv]
        ld = loads[bit]
        chunk = (len(ld) + ncopies - 1) // ncopies
        print("  %-58s %4d loads -> %d copies of ~%d" % (drv[-58:], n, ncopies, chunk))
        if args.dry_run:
            continue
        # copy 0 keeps the original driver and its first chunk
        for k in range(1, ncopies):
            maxbit += 1
            newbit = maxbit
            newname = "%s$rep%d" % (drv, k)
            newcell = json.loads(json.dumps(src))   # deep copy
            # rewire the copy's output to the fresh net
            for port, bits in newcell["connections"].items():
                if port in OUT_PORTS:
                    newcell["connections"][port] = [
                        newbit if b == bit else b for b in bits]
            newcell.setdefault("attributes", {})["keep"] = "00000000000000000000000000000001"
            cells[newname] = newcell
            added += 1
            # move this copy's share of the loads onto the new net
            for (lname, lport, lidx) in ld[k * chunk:(k + 1) * chunk]:
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
