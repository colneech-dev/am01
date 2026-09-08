#!/usr/bin/env python3
"""Is the natural layout near-optimal, or is there a middle ground between it
and cycle-order? Simulated annealing on the true combined cost, with
incremental delta evaluation (a swap touches only ~28 of the 4480 wires)."""
import re, random, math

SRC = "hdl/odocrypt/encrypt.v"
N, W, NW = 640, 64, 10
src = open(SRC).read()

def grab(name):
    m = re.search(r"module encrypt_4%s\(in, out\);(.*?)endmodule" % name, src, re.S)
    p = [0]*N
    for o, i in re.findall(r"assign out\[(\d+)\] = in\[(\d+)\];", m.group(1)):
        p[int(i)] = int(o)
    return p

p0, p1 = grab("apply_pbox0"), grab("apply_pbox1")
comp = [p1[p0[i]] for i in range(N)]
rots = [int(a)+1 for a in re.findall(r"\{in\[(\d+):0\], in\[63:\d+\]\}",
        re.search(r"module encrypt_4rotation_helper.*?assign out = (.*?);", src, re.S).group(1))]

# edge list: every wire as a (u,v) bit pair
edges = [(i, comp[i]) for i in range(N)]
for w in range(NW):
    for r in rots:
        for b in range(W):
            edges.append((w*W + b, w*W + (b - r) % W))

inc = [[] for _ in range(N)]
for e, (u, v) in enumerate(edges):
    inc[u].append(e)
    if v != u:
        inc[v].append(e)

def total(pos):
    return sum(abs(pos[u]-pos[v]) for u, v in edges)

def anneal(pos, iters, seed):
    rnd = random.Random(seed)
    pos = pos[:]
    cur = total(pos)
    best, bestpos = cur, pos[:]
    T0, T1 = 120.0, 0.4
    for k in range(iters):
        T = T0 * (T1/T0)**(k/iters)
        i = rnd.randrange(N); j = rnd.randrange(N)
        if i == j: continue
        touched = set(inc[i]); touched.update(inc[j])
        before = 0
        for e in touched:
            u, v = edges[e]; before += abs(pos[u]-pos[v])
        pos[i], pos[j] = pos[j], pos[i]
        after = 0
        for e in touched:
            u, v = edges[e]; after += abs(pos[u]-pos[v])
        d = after - before
        if d <= 0 or rnd.random() < math.exp(-d/T):
            cur += d
            if cur < best:
                best, bestpos = cur, pos[:]
        else:
            pos[i], pos[j] = pos[j], pos[i]
    return best, bestpos

natural = list(range(N))
print("natural           %9d" % total(natural))
for seed in (1, 2):
    b, _ = anneal(natural, 300000, seed)
    print("annealed seed %d   %9d   (%+.1f%% vs natural)" % (seed, b, 100*(b/total(natural)-1)))
