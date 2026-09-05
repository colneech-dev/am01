`--placer-heap-alpha` and `--placer-heap-beta` are silently discarded on the xilinx arch

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

`Arch::place()` overwrites `cfg.alpha`, `cfg.beta` and `cfg.criticalityExponent`
immediately after constructing `PlacerHeapCfg`. The constructor has already read
`placerHeap/alpha` and `placerHeap/beta` out of `ctx->settings`, which is exactly
where the command-line values are stored. The flags therefore parse, validate,
and then do nothing.

This is the worst failure mode for a tuning parameter: experiments appear to run
normally and produce plausible-looking results, while every one of them used the
same hardcoded value.

## Affected code

`xilinx/arch.cc`, `Arch::place()`:

```cpp
PlacerHeapCfg cfg(getCtx());       // ctor reads placerHeap/{alpha,beta,criticalityExponent}
cfg.criticalityExponent = 7;
cfg.ioBufTypes.insert(...);
cfg.alpha = 0.08;
cfg.beta  = 0.4;                   // <-- unconditional, clobbers the user's value
```

`common/placer_heap.cc`, `PlacerHeapCfg::PlacerHeapCfg`:

```cpp
alpha = ctx->setting<float>("placerHeap/alpha", 0.1);
beta  = ctx->setting<float>("placerHeap/beta", 0.9);
criticalityExponent = ctx->setting<int>("placerHeap/criticalityExponent", 2);
```

Introduced in `c9b9cab7` ("xilinx: Integration with placer updates", 2020-02-13),
so this has been present for over five years.

## Reproduction

Add a log line reporting the effective values, then:

```
nextpnr-xilinx --placer-heap-beta 0.25 ...
```

Observed: `beta=0.400`. Expected: `beta=0.250`.

## Suggested fix

Treat the arch values as defaults. The guard **must** be sampled *before* the
config is constructed, because `BaseCtx::setting<T>(name, def)`
(`common/nextpnr.h:896`) **inserts** the default when the key is absent:

```cpp
else settings[id(name)] = std::to_string(defaultValue);
```

so after the constructor returns, all three keys exist whether or not the user
passed anything, and a `settings.count()` test at that point is always true.

```cpp
const bool user_alpha = settings.count(id("placerHeap/alpha"));
const bool user_beta  = settings.count(id("placerHeap/beta"));
const bool user_crit  = settings.count(id("placerHeap/criticalityExponent"));

PlacerHeapCfg cfg(getCtx());
...
if (!user_alpha) cfg.alpha = 0.08;
if (!user_beta)  cfg.beta  = 0.4;
if (!user_crit)  cfg.criticalityExponent = 7;
```

(I initially tested *after* construction, which silently swapped the arch's tuned
values for the generic ones — alpha 0.08→0.1, criticalityExponent 7→2, and beta
0.4→0.9 for any run not passing the flag. Worth calling out, since it is an easy
trap to fall into when fixing this.)

## Secondary: the `--help` text for `beta` is misleading

`common/command.cc` describes beta as the "spreading trigger threshold". It is
not. In `common/placer_heap.cc`:

* `find_overused_regions()` seeds a region only on **strict** overflow,
  `occ_at(x,y,t) > bels_at(x,y,t)`. beta is never referenced there.
* beta is used only by `SpreaderRegion::overused(beta)` — how far an *already
  overflowing* region keeps **growing**.
* and that check ignores beta entirely when `bels.at(t) < 4`, so for
  2-bel-per-tile types (e.g. RAMB18 on 7-series) beta has no effect at any value.

Consequence: on a design where no tile exceeds 100% occupancy, no region is ever
seeded and beta cannot lower achieved density. That is worth documenting, because
it is intuitive to reach for beta to reduce routing congestion on a sparse device,
and it cannot help there.

## Context

Found while bringing up a large OdoCrypt miner on an xc7k325t through openXC7
(10% LUT / 47% RAMB18 utilisation). We were trying to tune placement spreading to
address a routing hotspot and could not understand why the parameter had no
effect.
