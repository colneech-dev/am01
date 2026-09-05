#!/usr/bin/env python3
"""Absorb fabric flip-flops on RAMB18E1 data outputs into the BRAM's own
optional output register (DOA_REG / DOB_REG).

WHY THIS EXISTS
---------------
The 7-series block RAM has an optional output register. Our Vivado-extracted
SDF (make-bram-timing-db.sh) prices it:

    DOA_REG_U_0  (output register OFF)  clk->DO  (1.353::2.454)
    DOA_REG_U_1  (output register ON)   clk->DO  (0.468::0.882)

~1.6 ns, on a design whose critical path spends 2.1 ns of a 7.7 ns period in
exactly that arc. Only 0.2 ns is needed to reach 133.33 MHz.

YOSYS CANNOT EMIT IT. This is not an oversight in our flow:

  * synth_xilinx.cc:519 selects brams_xc6v_map.v for family xc7, and that file
    hardcodes `.DOA_REG(0)` / `.DOB_REG(0)` (lines 52-53, 213-214).
  * The modern memory_libmap infrastructure that xc7 uses has no concept of an
    output register at all -- memlib.cc has no keyword for it.
  * The one `make_outreg` keyword in the tree belongs to the OLD memory_bram
    pass, and memory_bram.cc:1300 documents it as adding "external flip-flops"
    -- fabric flops, which is the thing we are trying to get rid of.

So no RTL coding style can produce DOA_REG=1 through inference. The register
has to be attached after mapping. That is what this does.

EVERYTHING DOWNSTREAM ALREADY SUPPORTS IT
-----------------------------------------
  * prjxray has the bitstream feature: kintex7/segbits_bram_l.db carries
    BRAM_L.RAMB18_Y0.DOA_REG at 27_69.
  * nextpnr-xilinx fasm.cc:2291 writes the bit.
  * nextpnr-xilinx arch.cc:2640 reads DOA_REG/DOB_REG in the timing model and
    selects the faster clock-to-Q, so the improvement shows up in the reported
    Fmax and not only on silicon.

Only the synthesis step was missing.

WHAT IT TRANSFORMS
------------------
Input is a netlist built from odo_gen --bram-out-reg, whose S-boxes read

    q1  <= mem[addr];     // the BRAM's internal read register
    out <= q1;            // intended as the output register; lands in fabric

The second stage becomes an FDRE per bit sitting on the BRAM output. This pass
deletes those flops and turns the register on inside the BRAM instead:

    BRAM.DO --netX--> FDRE.D  FDRE.Q --netY-->        (before)
    BRAM.DO --netY-->                                  (after, DOA_REG=1)

CONSERVATIVE BY CONSTRUCTION
----------------------------
A side is transformed only when all of these hold, and is left completely alone
otherwise:

  - every data output bit of that side drives exactly one load
    (a second load would still need the *unregistered* value, which no longer
    exists once the register is switched on -- this is the correctness crux)
  - that load is the D pin of an FDRE
  - no bit escapes to a top-level port
  - all the flops share one clock, and it is the BRAM's own clock for that side
  - their CE is constant 1 and R is constant 0, so the BRAM's REGCE/RSTREG can
    be tied to match without carrying logic across

Refusing is always safe; it just leaves that side at the slower timing.

Usage:
    absorb_bram_outreg.py in.json out.json [--report report.txt]
"""
import json
import sys
from collections import defaultdict, Counter

FLOP = "FDRE"
# Data outputs per side, with the control pins and parameter names that go with
# them. Parity bits (DOP*) ride the same register and must be treated together.
SIDES = {
    "A": dict(data=["DOADO", "DOPADOP"], clk="CLKARDCLK",
              regce="REGCEAREGCE", rstreg="RSTREGARSTREG", param="DOA_REG"),
    "B": dict(data=["DOBDO", "DOPBDOP"], clk="CLKBWRCLK",
              regce="REGCEB", rstreg="RSTREGB", param="DOB_REG"),
}


def is_const(bits, val):
    return bool(bits) and all(b == val for b in bits)


def main():
    # Hand-rolled rather than argparse so the usage text stays the docstring.
    # --report takes a value, so consume it as a pair; otherwise its filename
    # would be mistaken for a positional argument.
    argv, args, report_path = sys.argv[1:], [], None
    i = 0
    while i < len(argv):
        if argv[i] == "--report" and i + 1 < len(argv):
            report_path = argv[i + 1]
            i += 2
        elif argv[i].startswith("--"):
            i += 1
        else:
            args.append(argv[i])
            i += 1
    if len(args) != 2:
        print(__doc__)
        return 2
    src, dst = args

    log = []

    def say(s):
        print(s)
        log.append(s)

    say("reading %s" % src)
    with open(src) as fh:
        design = json.load(fh)

    mod = design["modules"]["am01_qmtech_top"]
    cells = mod["cells"]

    # ---- connectivity: one driver, many consumers, per net bit -------------
    consumers = defaultdict(list)
    for cn, c in cells.items():
        dirs = c.get("port_directions", {})
        for port, bits in c["connections"].items():
            if dirs.get(port, "input") == "output":
                continue
            for b in bits:
                if isinstance(b, int):
                    consumers[b].append((cn, port))
    # A bit reaching a module output port must keep its unregistered timing.
    for pname, p in mod.get("ports", {}).items():
        if p.get("direction") in ("output", "inout"):
            for b in p["bits"]:
                if isinstance(b, int):
                    consumers[b].append(("<top:%s>" % pname, "<port>"))

    brams = [n for n, c in cells.items() if c["type"] == "RAMB18E1"]
    say("RAMB18E1 cells: %d" % len(brams))

    reasons = Counter()
    doomed = set()          # flops to delete
    removed_bits = set()    # intermediate BRAM->flop nets, now unreferenced
    n_sides = 0

    for bn in brams:
        c = cells[bn]
        for side, S in SIDES.items():
            if str(c["parameters"].get(S["param"], 0)).lstrip("0") not in ("", "0"):
                reasons["skipped: already registered"] += 1
                continue

            # bit -> flop, for every driven output bit of this side
            pairs, ok, why = [], True, None
            for port in S["data"]:
                for idx, b in enumerate(c["connections"].get(port, [])):
                    if not isinstance(b, int):
                        continue
                    ld = consumers.get(b, [])
                    if not ld:
                        continue                      # dangling bit: nothing to do
                    if len(ld) > 1:
                        ok, why = False, "output bit has multiple loads"
                        break
                    lc, lp = ld[0]
                    if lc.startswith("<top:"):
                        ok, why = False, "output reaches a top-level port"
                        break
                    if cells[lc]["type"] != FLOP:
                        ok, why = False, "load is %s, not %s" % (cells[lc]["type"], FLOP)
                        break
                    if lp != "D":
                        ok, why = False, "load pin is %s, not D" % lp
                        break
                    pairs.append((port, idx, b, lc))
                if not ok:
                    break

            if not ok:
                reasons["skipped: " + why] += 1
                continue
            if not pairs:
                reasons["skipped: side unused"] += 1
                continue

            # Control must be uniform, trivial, and on the BRAM's own clock.
            bramclk = c["connections"].get(S["clk"], [])
            bad = None
            for _, _, _, fn in pairs:
                fc = cells[fn]
                if fc["connections"].get("C", []) != bramclk:
                    bad = "flop clock differs from BRAM clock"
                    break
                if not is_const(fc["connections"].get("CE", []), "1"):
                    bad = "flop CE is not constant 1"
                    break
                if not is_const(fc["connections"].get("R", []), "0"):
                    bad = "flop R is not constant 0"
                    break
            if bad:
                reasons["skipped: " + bad] += 1
                continue

            # A flop must not be claimed twice (it cannot be, since D is one
            # pin, but assert rather than trust).
            for _, _, _, fn in pairs:
                assert fn not in doomed, "flop %s claimed twice" % fn

            # ---- rewire: BRAM drives the flop's Q net directly -------------
            for port, idx, b, fn in pairs:
                qbits = cells[fn]["connections"].get("Q", [])
                assert len(qbits) == 1, "%s has %d Q bits" % (fn, len(qbits))
                c["connections"][port][idx] = qbits[0]
                removed_bits.add(b)
                doomed.add(fn)

            c["parameters"][S["param"]] = 1
            # Turn the register on: clock-enable high, reset low. RSTREG is
            # already constant 0 in this netlist; set it explicitly anyway so
            # the result does not depend on that remaining true.
            width = len(c["connections"].get(S["regce"], ["0"])) or 1
            c["connections"][S["regce"]] = ["1"] * width
            width = len(c["connections"].get(S["rstreg"], ["0"])) or 1
            c["connections"][S["rstreg"]] = ["0"] * width
            n_sides += 1
            reasons["ABSORBED"] += 1

    for fn in doomed:
        del cells[fn]

    # Netnames for the now-vanished intermediate nets would reference bits with
    # no driver. Harmless to nextpnr, but drop them so the JSON stays honest.
    dropped = 0
    nn = mod.get("netnames", {})
    for name in list(nn):
        bits = nn[name].get("bits", [])
        if bits and all(isinstance(b, int) and b in removed_bits for b in bits):
            del nn[name]
            dropped += 1

    say("")
    for k, v in sorted(reasons.items(), key=lambda x: -x[1]):
        say("  %-46s %d" % (k, v))
    say("")
    say("  BRAM sides registered : %d" % n_sides)
    say("  flip-flops removed    : %d" % len(doomed))
    say("  cells before/after    : %d -> %d" % (len(cells) + len(doomed), len(cells)))

    if n_sides == 0:
        say("")
        say("  NOTHING CHANGED -- refusing to write an output that is just a copy.")
        say("  Was this netlist built with odo_gen --bram-out-reg?")
        return 1

    say("")
    say("writing %s" % dst)
    with open(dst, "w") as fh:
        json.dump(design, fh)

    if report_path:
        with open(report_path, "w") as fh:
            fh.write("\n".join(log) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
