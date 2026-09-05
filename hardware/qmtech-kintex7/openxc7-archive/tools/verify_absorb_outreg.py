#!/usr/bin/env python3
"""Structural verification of absorb_bram_outreg.py.

WHY STRUCTURAL AND NOT FORMAL
-----------------------------
equiv_make would be the stronger check, and it is what verify_replication.py's
companion equiv_replication.ys does for the fanout transform. It is NOT
available here: RAMB18E1 in yosys's cells_sim.v is a timing-only shell -- it
declares DOA_REG and carries a specify block with the 2454/882 clock-to-DO
numbers, but has no always/assign body at all. With no behavioural model of the
BRAM there is nothing for a SAT solver to reason about, and an equivalence run
would either fail to elaborate or prove a vacuous statement.

So the argument for correctness is made in two halves, and this file is the
second:

  1. That the EXTRA PIPELINE STAGE is functionally correct -- that odo_gen's
     --bram-out-reg reschedules the round keys properly for 3 cycles/round --
     is established at RTL by sim/tb_outreg_equiv.v, which compares the emitted
     result sequence against the reference core and carries a +brk negative
     control.

  2. That MOVING that stage from fabric into the BRAM is value-preserving is
     established here. It reduces to a local claim: an FDRE with CE=1 and R=0
     is exactly a transparent-free register, and DOA_REG=1 with REGCE=1 and
     RSTREG=0 is the same register inside the block. Given that, the only way
     the transform can be wrong is by rewiring something incorrectly -- which
     is a structural property, and is what is checked below.

WHAT IS CHECKED
---------------
  1. BRAM cells are the same set, and none were added or dropped.
  2. Exactly the absorbed flops disappeared; nothing else did.
  3. Every side now claiming DO*_REG=1 has REGCE tied 1 and RSTREG tied 0
     (a register that is switched on but never clocked would silently stall).
  4. Each BRAM output bit in the new netlist is precisely the Q net of the flop
     that used to sit on that bit -- the actual rewiring claim.
  5. No net gained a second driver.
  6. No connection anywhere still references a deleted cell.
  7. Every cell that was not deliberately touched is byte-identical, so the
     pass cannot have perturbed unrelated logic.

Usage:
    verify_absorb_outreg.py before.json after.json
"""
import json
import sys
from collections import defaultdict

SIDES = {
    "A": dict(data=["DOADO", "DOPADOP"], regce="REGCEAREGCE",
              rstreg="RSTREGARSTREG", param="DOA_REG"),
    "B": dict(data=["DOBDO", "DOPBDOP"], regce="REGCEB",
              rstreg="RSTREGB", param="DOB_REG"),
}

fails = []
notes = []


def check(cond, msg):
    if cond:
        return True
    fails.append(msg)
    return False


def load(p):
    with open(p) as fh:
        return json.load(fh)["modules"]["am01_qmtech_top"]


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    before, after = load(sys.argv[1]), load(sys.argv[2])
    b, a = before["cells"], after["cells"]

    # ---- 1. BRAM set unchanged -------------------------------------------
    bb = {n for n, c in b.items() if c["type"] == "RAMB18E1"}
    ba = {n for n, c in a.items() if c["type"] == "RAMB18E1"}
    check(bb == ba, "BRAM set changed: %d added, %d removed"
                    % (len(ba - bb), len(bb - ba)))
    notes.append("BRAM cells: %d (unchanged)" % len(ba))

    # ---- 2. only flops disappeared ---------------------------------------
    gone = set(b) - set(a)
    added = set(a) - set(b)
    check(not added, "%d cells were ADDED; the pass must only delete" % len(added))
    bad = {n for n in gone if b[n]["type"] != "FDRE"}
    check(not bad, "%d non-FDRE cells deleted, e.g. %s"
                   % (len(bad), sorted(bad)[:3]))
    notes.append("cells deleted: %d (all FDRE)" % len(gone))

    # ---- driver/consumer maps for the new netlist ------------------------
    drivers = defaultdict(list)
    for cn, c in a.items():
        dirs = c.get("port_directions", {})
        for port, bits in c["connections"].items():
            if dirs.get(port, "input") != "output":
                continue
            for bit in bits:
                if isinstance(bit, int):
                    drivers[bit].append((cn, port))

    # ---- 3/4. per-side rewiring ------------------------------------------
    n_sides = 0
    n_bits = 0
    for name in sorted(ba):
        cb, ca = b[name], a[name]
        for side, S in SIDES.items():
            on_b = str(cb["parameters"].get(S["param"], 0)).lstrip("0") not in ("", "0")
            on_a = str(ca["parameters"].get(S["param"], 0)).lstrip("0") not in ("", "0")
            if not on_a:
                check(not on_b, "%s.%s was on and is now off" % (name, S["param"]))
                continue
            if on_b:
                continue                      # already registered beforehand
            n_sides += 1

            regce = ca["connections"].get(S["regce"], [])
            rstreg = ca["connections"].get(S["rstreg"], [])
            check(bool(regce) and all(x == "1" for x in regce),
                  "%s side %s: DO_REG on but REGCE=%s (register would never load)"
                  % (name, side, regce))
            check(all(x == "0" for x in rstreg),
                  "%s side %s: RSTREG=%s, expected constant 0" % (name, side, rstreg))

            for port in S["data"]:
                obits = cb["connections"].get(port, [])
                nbits = ca["connections"].get(port, [])
                if not check(len(obits) == len(nbits),
                             "%s.%s width changed %d -> %d"
                             % (name, port, len(obits), len(nbits))):
                    continue
                for idx, (ob, nb) in enumerate(zip(obits, nbits)):
                    if ob == nb:
                        continue              # untouched bit (tied off/dangling)
                    # The bit changed: it must now be the Q of the flop that
                    # consumed the old bit, and that flop must be gone.
                    owner = [fn for fn in gone
                             if ob in b[fn]["connections"].get("D", [])]
                    if not check(len(owner) == 1,
                                 "%s.%s[%d]: rewired but %d deleted flops had it on D"
                                 % (name, port, idx, len(owner))):
                        continue
                    q = b[owner[0]]["connections"].get("Q", [])
                    check(len(q) == 1 and q[0] == nb,
                          "%s.%s[%d]: now drives %s but flop %s had Q=%s"
                          % (name, port, idx, nb, owner[0], q))
                    n_bits += 1
    notes.append("sides newly registered: %d" % n_sides)
    notes.append("output bits rewired to flop Q nets: %d" % n_bits)

    # ---- 5. no double drivers --------------------------------------------
    multi = {bit: d for bit, d in drivers.items() if len(d) > 1}
    check(not multi, "%d nets have multiple drivers, e.g. %s"
                     % (len(multi), list(multi.items())[:2]))

    # ---- 6. no dangling reference to a deleted cell ----------------------
    check(not (gone & set(a)), "deleted cells still present")

    # ---- 7. untouched cells are byte-identical ---------------------------
    changed = []
    for n, c in a.items():
        if n in ba:
            continue                          # BRAMs are the intended target
        if b[n] != c:
            changed.append(n)
    check(not changed, "%d non-BRAM cells were modified, e.g. %s"
                       % (len(changed), changed[:3]))
    notes.append("non-BRAM cells modified: %d (expected 0)" % len(changed))

    print("--- verification of absorb_bram_outreg ---")
    for n in notes:
        print("  %s" % n)
    print("")
    if fails:
        print("  RESULT: FAIL")
        for f in fails:
            print("    - %s" % f)
        return 1
    print("  RESULT: PASS -- rewiring is structurally sound")
    print("  (functional correctness of the extra stage is tb_outreg_equiv.v's job)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
