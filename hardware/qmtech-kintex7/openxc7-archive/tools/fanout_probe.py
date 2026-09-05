#!/usr/bin/env python3
"""Where does the 644 fanout on crypt.progress[1] actually come from?

In RTL that signal drives exactly ONE load: encrypt.v:15519 passes it as the
`read` port of encrypt_4encrypt_loop, and inside that module `read` drives only
progress[0] of a pure 172-stage shift register whose only consumer is
`assign write = progress[171]`.

Vivado reports fanout 644 on the routed netlist. So synthesis created the
fanout. This finds the driver cell, counts its real loads, and reports what
kinds of cells they are -- which decides whether the fix belongs in the RTL or
in the toolchain.
"""
import json
from collections import Counter

BASE = ("/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/"
        "openxc7/out_nm1_nosr/")
JSON = BASE + "am01_qmtech_top_v68.json"
DRIVER = "$auto$ff.cc:337:slice$466022"

print("loading netlist...")
d = json.load(open(JSON))
mods = d["modules"]
top = next(m for m in mods if mods[m].get("attributes", {}).get("top"))
cells = mods[top]["cells"]
nets = mods[top].get("netnames", {})

drv = cells.get(DRIVER)
if drv is None:
    raise SystemExit("driver cell %s not in netlist" % DRIVER)

print("driver: %s  type=%s" % (DRIVER, drv["type"]))
qbits = [b for b in drv["connections"].get("Q", []) if isinstance(b, int)]
print("  Q bits: %s" % qbits)

for qb in qbits:
    loads = []
    for name, c in cells.items():
        if name == DRIVER:
            continue
        for port, bits in c.get("connections", {}).items():
            if port == "Q":
                continue
            if qb in [b for b in bits if isinstance(b, int)]:
                loads.append((name, c["type"], port))
                break
    print("\n  net bit %d -> %d loads" % (qb, len(loads)))
    print("    load cell types: %s" % dict(Counter(t for _, t, _ in loads).most_common(8)))
    print("    load ports     : %s" % dict(Counter(p for _, _, p in loads).most_common(8)))

    # What RTL scope do the loads belong to? If they are spread over many
    # scopes, one signal is genuinely broadcast design-wide.
    scopes = Counter()
    for n, _, _ in loads:
        h = cells[n].get("attributes", {}).get("hdlname") or "(none)"
        scopes[str(h).split("|")[0][:70]] += 1
    print("    load RTL scopes (top 5):")
    for s, k in scopes.most_common(5):
        print("      %5d  %s" % (k, s))

    # Name of the net, if yosys kept one.
    for nn, ni in nets.items():
        if qb in [b for b in ni.get("bits", []) if isinstance(b, int)]:
            print("    net name: %s" % nn[:100])
            break
