router2 closes wires on first push rather than first pop, making the cost-relaxation branch dead code

> **RE-CHECKED 2026-08-22.** Still valid against the merged tree (nextpnr-xilinx
> at openXC7 HEAD, 25 commits newer than when this was written) — the code this
> describes is unchanged there. NOT YET FILED.
>
> Worth checking again immediately before filing: two other issues written the
> same way turned out to be **already fixed upstream** (a nextpnr control-set bug,
> and a `synth_xilinx` split-run bug fixed after v0.68). A stale tree reproduces
> its own bugs perfectly, so verify against `YosysHQ/nextpnr` HEAD, not this fork.
>
> Related filings: YosysHQ/nextpnr#1784, YosysHQ/yosys#6144, YosysHQ/yosys#6145.


## Summary

In `router2`'s forward search, a wire is marked visited when it is **pushed**
onto the queue, and an early `continue` rejects any wire already visited. The
relaxation test below it therefore can never see `v.visited == true`, so its
second clause is unreachable and a wire's cost is never improved once set.

The practical effect is that **the first path to touch a wire owns it
permanently**, at whatever cost it happened to arrive with — and every wire
expanded from it inherits that cost. This is not A\*.

## Affected code

`common/router2.cc`, in the arc search loop:

```cpp
WireId next = ctx->getPipDstWire(dh);
int next_idx = wire_to_idx.at(next);
if (was_visited(next_idx))
    continue;                                    // <-- closes the wire HERE
...
const auto &v = nwd.visit;
if (!v.visited || (v.score.total() > next_score.total())) {   // <-- can never be false
    ++explored;
    t.queue.push(QueuedWire(next_idx, dh, ctx->getPipLocation(dh), next_score, t.rng.rng()));
    set_visited(t, next_idx, dh, next_score);
    ...
}
```

`set_visited()` sets `v.visited = true`, and it is called at push time. So by the
time the `if` is reached, `v.visited` is always false and
`|| (v.score.total() > next_score.total())` is dead.

Present since `2de98386` ("router2: Experiment with data structures",
2020-01-14).

## Why this is a bug rather than a deliberate optimisation

Closing a node on first **pop** is standard and correct: with a consistent
heuristic, the first pop of a node is guaranteed optimal. That guarantee gives no
licence to close on **push** — a node can easily be pushed first via an expensive
path and later reached more cheaply.

The relaxation branch immediately below appears to have been written with the
intent of handling exactly that case; it is simply shadowed by the early
`continue`.

## Observed effect

On a large OdoCrypt design (xc7k325t, ~1.7M wires), enabling relaxation by
skipping the early `continue` measurably improved route quality:

```
                      overused wires    total wires
iter 1   baseline     135026            1399222
iter 1   relaxed      132250 (-2.1%)    1396211
iter 2   baseline     117996            1462921
iter 2   relaxed      114231 (-3.2%)    1460948
iter 3   baseline      99965            1506613
iter 3   relaxed       94261 (-5.7%)    1504912
```

Fewer wires *and* less congestion, with the margin widening — consistent with
routes genuinely being shorter once costs can be improved.

## Caveat: the naive fix is expensive

Simply removing the `continue` cost roughly **22 min/iteration versus ~5** on this
design, because every marginal cost improvement re-pushes a wire and re-expands
everything downstream of it.

Thresholding the improvement helps but is not free — requiring a 5% improvement
recovered about half the quality gain and only modestly reduced the cost:

```cpp
bool improved = !v.visited ||
                (v.score.total() > next_score.total() * (1.0f + relax_eps));
```

So the correct fix probably needs more thought than deleting one line — perhaps
closing on pop rather than push, which is the textbook formulation and would
avoid the repeated re-expansion entirely. Filing this primarily to flag that the
branch is unreachable and that the current behaviour is not A\*, rather than to
propose the one-line change.

## Context

Found while investigating why a design that Vivado routes successfully was
leaving arcs permanently unrouted under openXC7. Diagnostics showed the failing
searches exhausting their visit budget while the frontier's heuristic distance to
the sink stayed flat — i.e. exploring a large region without closing distance,
which is consistent with a corrupted cost landscape.
