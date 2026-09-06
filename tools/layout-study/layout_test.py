#!/usr/bin/env python3
"""Does an algebra-derived layout actually beat the naive one?

Tests the claim in IMPLEMENTATION-REVIEW.md sec.7: that the constant rotations
and word shuffle could be absorbed into the placement of pipeline registers,
making the p-box wiring short by construction.

Model. One round maps register bits to register bits by comp = pbox1 o pbox0
(the S-box is position-wise the identity -- it permutes VALUES, not positions).
The linear mix then XORs six constant rotations of each 64-bit word.

A layout is an assignment of the 640 state bits to 640 physical positions.
Cost is total wirelength in position units (1-D, |delta| -- a proxy, but the
right one for asking whether ANY relabeling helps, since it is layout-relative):

    permutation wires:  sum_i |pos[comp(i)] - pos[i]|            (640 wires)
    linear-mix taps:    sum over words, 6 rotations, 64 bits     (3840 wires)

Layouts compared:
    natural      bit i at position i (what the tools see today)
    cycle-order  bits laid out along the cycles of comp, so the permutation
                 becomes a distance-1 hop -- the best possible layout for the
                 permutation term alone
    annealed     simulated annealing on the true combined cost
"""
import re, random, collections

SRC = "hdl/odocrypt/encrypt.v"
N, W, NW = 640, 64, 10

def grab(name):
    src = open(SRC).read()
    m = re.search(r"module encrypt_4%s\(in, out\);(.*?)endmodule" % name, src, re.S)
    p = [0]*N
    for o, i in re.findall(r"assign out\[(\d+)\] = in\[(\d+)\];", m.group(1)):
        p[int(i)] = int(o)
    return p

p0, p1 = grab("apply_pbox0"), grab("apply_pbox1")
comp = [p1[p0[i]] for i in range(N)]

# rotation_helper: {in[63-r:0], in[63:64-r]} is a rotate-left by r+1 ... read the
# six shift amounts straight out of the emitted expression.
rots = [int(a)+1 for a in re.findall(r"\{in\[(\d+):0\], in\[63:\d+\]\}",
        re.search(r"module encrypt_4rotation_helper.*?assign out = (.*?);",
                  open(SRC).read(), re.S).group(1))]
assert len(rots) == 6, rots

def cost(pos):
    """pos[bit] -> physical slot. Returns (permutation, linmix, total)."""
    perm = sum(abs(pos[comp[i]] - pos[i]) for i in range(N))
    lin = 0
    for w in range(NW):
        base = w*W
        for r in rots:
            for b in range(W):
                lin += abs(pos[base + b] - pos[base + (b - r) % W])
    return perm, lin, perm + lin

# ---- natural -------------------------------------------------------------
natural = list(range(N))

# ---- cycle-order: optimal for the permutation term alone -----------------
cyc_pos = [0]*N
seen = [False]*N
slot = 0
for s in range(N):
    if seen[s]:
        continue
    x = s
    while not seen[x]:
        seen[x] = True
        cyc_pos[x] = slot
        slot += 1
        x = comp[x]
assert sorted(cyc_pos) == list(range(N))

# ---- annealed on the real cost ------------------------------------------
def anneal(start, iters=400000, seed=1):
    rnd = random.Random(seed)
    pos = start[:]
    cur = cost(pos)[2]
    best, bestpos = cur, pos[:]
    T0, T1 = N/2.0, 0.5
    for k in range(iters):
        T = T0 * (T1/T0)**(k/iters)
        i, j = rnd.randrange(N), rnd.randrange(N)
        if i == j:
            continue
        pos[i], pos[j] = pos[j], pos[i]
        new = cost(pos)[2]
        if new <= cur or rnd.random() < pow(2.718281828, -(new-cur)/T):
            cur = new
            if new < best:
                best, bestpos = new, pos[:]
        else:
            pos[i], pos[j] = pos[j], pos[i]
    return bestpos

print("rotations in the linear mix:", rots)
print()
print("%-14s %12s %12s %12s" % ("layout", "permutation", "linear-mix", "TOTAL"))
rows = [("natural", natural), ("cycle-order", cyc_pos)]
base = None
for nm, pos in rows:
    p, l, t = cost(pos)
    if base is None:
        base = t
    print("%-14s %12d %12d %12d   (%+.0f%%)" % (nm, p, l, t, 100*(t/base-1)))

ann = anneal(natural, iters=200000)
p, l, t = cost(ann)
print("%-14s %12d %12d %12d   (%+.0f%%)" % ("annealed", p, l, t, 100*(t/base-1)))
