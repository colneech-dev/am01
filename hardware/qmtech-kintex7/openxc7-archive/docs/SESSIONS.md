# openXC7 bring-up: session record

Newest first. Earlier entries are kept for the reasoning, not the numbers —
figures from before the 2026-08-22 toolchain change (yosys 0.62 -> v0.68,
nextpnr 0.9.2 -> openXC7 HEAD) are **not comparable** with anything after it,
because v0.68 produces a different netlist.

See `README.md` for the document index and current state.

---

## 2026-08-22 — the gap is placement, and the target is reachable

Two results settle questions that were open for days, and one correction
invalidates a number this project has been steering by.

## 1. The ceiling, measured: 158.81 MHz

`vivado_route_own_placement.tcl` — Vivado place + Vivado route on **our yosys
netlist** (NUM_MINERS=1):

```
clk_h   period 7.500 ns   WNS +1.203   ->  6.297 ns = 158.81 MHz    PASS @ 133.33
Number of Unrouted Nets = 0     Number of Node Overlaps = 0
0 critical warnings, 0 errors
```

**The design meets its 133.33 MHz target on this part with this RTL.** That was
genuinely unknown before today, and it means the BRAM-output-register rework
(and the sbox restructuring that would follow it) is not required to hit spec.

It also closes the synthesis question. Our netlist reaches 158.81 MHz where
Vivado's own synthesis reaches 162 — ~2% apart, and that comparison favours
Vivado, whose run was NUM_MINERS=2. There is no meaningful synthesis headroom.

| place | route | Fmax | notes |
|---|---|---|---|
| nextpnr | nextpnr | **102.15** | 0 unrouted (`_st`, striped) |
| Vivado | *(place only)* | 176.43 | pre-route estimate |
| **Vivado** | **Vivado** | **158.81** | 0 unrouted, **meets target** |
| nextpnr | Vivado | — | unblocked today, not yet run |

**openXC7 is at 64% of Vivado on identical input.** That 1.55× is entirely
place-and-route.

## 2. Correction: the best result is 102.15 MHz, not 92.36

Most of this session reported 92.36 MHz (Y-band floorplan) as the best result
and recorded the Y-band change as a **+12% improvement**. Reading the logs
directly:

```
_st      102.15 MHz   0 unrouted   <- actual best (striped)
_yb       92.36 MHz   0 unrouted
_sy1      90.46
_hs       89.93
_reach    84.42
```

Both runs constrain the same 420 BRAMs over the same X/Y span and differ only in
the allocation (constraint fingerprints `7c1dfef` vs `cae951e`), so this is a
clean single-variable comparison: **Y-band is a ~10% regression, not a gain.**

Consequences:
- The Y-band floorplan commit needs reverting or re-justifying.
- The 102.15 run has **no saved placement** — `placed.json` (17:26) predates
  `am01_qmtech_top_st.json` (17:29), so it is the harvest placement, not the
  result. A nextpnr re-run with `--write` is needed before that placement can be
  handed to Vivado's router.
- The XDC exported for the router experiment came from `placed_yb.json`, i.e.
  the *worse* placement.

## 3. The real constraint: the floorplan addresses 0.6% of the design

Cell-name census of the shipped netlist:

| kind | count |
|---|---|
| `$abc$…parse_blif$N` | 41,809 |
| `$auto$ff.cc:337:slice$N` | 27,614 |
| **hierarchical (addressable)** | **423** |

`floorplan_stripe.py` constrains **420 of 69,869 cells**. Striped and Y-band were
both rearrangements of that same 0.6% — which is the best explanation yet for
why so many placer knobs refuted this session. Global cost-function tuning was
being applied while 99.4% of the design floated free.

And the critical path is not BRAM-limited. The same arc in both tools:

```
Vivado  RAMB18E1 2.080 -> net(fo=7) 3.146 -> LUT6 0.053 -> net 0.641 -> LUT2 -> FDRE
ours    RAMB18   2.1   -> net       6.9   -> LUT6 0.2   -> net 1.3   -> LUT6 -> FDRE
```

Same source, same sink, same two LUT levels, same fanout-7 net. The entire gap is
**one net: 3.146 ns vs 6.9 ns**. It ends at a LUT at tile (113,251) whose BRAM is
at (19,5). The misplaced cell is a **LUT**, and no floorplan could reach it.

### Recovery

Cell names are anonymous; **net** names are not. `derive_round_index.py` recovers
a round index for **51,621 cells**:

| type | resolved | total | |
|---|---|---|---|
| LUT6 | 18,480 | 19,406 | 95.2% |
| LUT2 | 13,257 | 13,732 | 96.5% |
| FDRE | 19,281 | 27,607 | 69.8% |
| RAMB18E1 | 420 | 420 | 100% |

Histogram is uniform at ~2,427 for rounds 0–19 (round 20 is 3,068, feeding the
output stage) — the expected shape for 21 identical rounds. The LUT6 and FDRE
counts were independently reproduced by a separate review agent, to the digit.

**A correctness trap caught before use:** an earlier version broke aliasing ties
by keeping the lowest round. Exactly **one** bit in this design is named with all
21 rounds — a global signal threaded through every round's hierarchy — and it
swept **8,786 cells into round 0**, inflating it to 11,214 against a true 2,428.
Constraining those would have dragged unrelated logic across the die and quietly
poisoned the floorplan. Multi-round bits are now discarded.

`preplace_round_regions.py` applies this through nextpnr's `--pre-place` hook as
**regions, not exact BELs** — pinning 51,621 cells would over-constrain the
placer. HeAP honours regions where placement is decided: `placer_heap.cc:892-900`
clamps the analytical solve via `limit_to_reg`, `:1047` limits spreader radius.
Each round's box derives from where that round's own BRAMs landed, so it composes
with `floorplan_stripe.py` rather than fighting it.

## 4. Synthesis findings (from the independent review)

- **2 LUT levels is the floor, not fat.** The rotation network is a genuine
  7-input XOR per bit (`encrypt.v:14824-14828` plus a 7th term at `:14844`).
  Vivado reaches 2 levels as well. All 11,760 BRAM ADDR pins are at depth 0.
- **LUT7 cost-model defect, ~15% upside.** yosys charges LUT7 = 10 vs
  LUT6+LUT2 = 7, but on silicon both occupy two 6-LUT sites — the MUXF7 is free
  hardware. `abc.cc` hardcodes delay to 1.00 for every LUT size. Test:
  `abc -luts 2:2,3,6:5,6,12`, expect MUXF7 to go 294 → ~13,400.
- **Do not use `-retime`** — deepens 2→6 levels and reintroduces the FDSE cells
  the dfflegalize workaround exists to remove.
- **Do not use `-abc9`** — zero MUXF7 here, and incompatible with the committed
  script as written (leaves 1,527 FFs unmapped).
- **T15 (drop dfflegalize workaround) won't move Fmax.** All 27,607 FDREs
  already have CE=1/R=0, and the sbox registers have no CE or reset in RTL, so
  it is a no-op on the critical path. Worth doing to retire a workaround for an
  upstream-fixed bug; not for timing.
- **Reproducibility gap:** `synth_fdre_only.ys` reads a scratchpad temp path and
  the NUM_MINERS=1 top level is not in the repo, so neither it nor `build.sh`
  reproduces the shipped netlist.

## 5. Doc error to fix

`hdl/sbox_large_mux2.v:82-84` blames its failure on the S-box address not being
register-driven. All 11,760 `RAMB18E1` ADDR pins are at logic depth 0, driven
from `FDRE.Q` through pure rewiring. The address *is* registered; it is late
because of **net delay**. The 1.22× measured result and the structural-ceiling
conclusion stand — only the stated mechanism is wrong. The prescription at :95
("register the S-box address") would add a register where one already exists.

## Still to run

1. **Region-constrained nextpnr run** — `--pre-place preplace_round_regions.py`.
   The payoff experiment. Success: the BRAM→LUT arc's net budget drops from
   6.9 ns toward Vivado's 3.146 ns.
2. **`nextpnr place → Vivado route`** — name mapping fixed today; needs the
   match-rate gate to pass, and should use a re-run `_st` placement, not `_yb`.
3. **LUT7 cost fix** — `abc -luts 2:2,3,6:5,6,12`.
4. **Re-run `_st` with `--write`** to capture the 102.15 MHz placement.
5. **Revert or re-justify the Y-band floorplan.**
6. **Re-examine the placer verdicts** measured against `predictDelay` rather than
   a trustworthy metric — though task 4's 84.42 vs 102.15 is wide enough that it
   is unlikely to flip.


---

## 2026-08-21 — what was done, what it proved, what is still untested

> **SUPERSEDED 2026-08-22.** Read `SESSION-2026-08-22.md` and `README.md` first.
>
> Two things here no longer hold:
> * The **102.15 MHz** striped result is not reproducible on the current
>   toolchain, and a control run on the old one landed at 89.82 MHz on identical
>   input — a 12% gap that was never explained. Treat every figure in this file
>   as provisional.
> * The toolchain has moved from yosys 0.62 / nextpnr 0.9.2 to yosys v0.68 /
>   nextpnr at openXC7 HEAD. v0.68 produces a different netlist (~1500 fewer small
>   LUTs), so figures either side of that boundary are not comparable at all.


Session of 2026-08-20/21. Written so the dead ends are as recoverable as the wins
— several hours went into hypotheses that measurement refuted, and re-deriving
them would be pure waste.

---

## Headline

| | before | after |
|---|---|---|
| unrouted arcs | **447** | **0** |
| overused wires | 0 | 0 |
| arch failures | 0 | 0 |
| iterations / runtime | 164 / 13.4 h | 10 / ~22 min |
| reproducible across seeds | no (17 … 2464) | **yes, 4/4 seeds** |
| `clk_h` Fmax | *unmeasurable* | **65.19 MHz** (target 133.33) |

Routing is **solved**. Timing is now the binding constraint, and for the first
time it is honestly measured — every earlier Fmax figure was fabric-only.

**Vivado reference on the same part with twice the BRAMs: 162 MHz, WNS +1.327 ns.**

---

## Committed changes

### nextpnr (`/home/colin/src/nextpnr-xilinx-heatmap`)

| commit | what | why |
|---|---|---|
| `28d98d9` | requeue abandoned arcs; bound congestion cost | 447 → 17 unrouted. Failed arcs were logged once and dropped — `failed_nets` is populated purely from congestion, and `route_net`'s return value is discarded at all three call sites. Separately, `curr_cong_weight` grew unbounded (+2.0/iter, ~200x by iter 100), pricing contested hops out of reach so negotiation could not function. |
| `cb459ac` | block RAM into the timing graph | RAMB ports fell through to `TMG_IGNORE`, so all 420 memories were **invisible to STA**. Reported Fmax was the worst LUT-to-LUT path on a 47%-BRAM design. Uses real Vivado-measured 2.080 ns clock→DO. |
| `af865fb` | isotropic routing heuristic (`NEXTPNR_ISO_HEURISTIC`) | `estimateDelay` charges y at 2x the x rate; prjxray's own kintex7 pip delays show the fabric is not anisotropic that way. Overestimating `h` turns A* into greedy best-first. `predictDelay` patched identically because criticality is computed from it. |
| `3ce1773` | criticality fixes + instrumentation | Stale `max_crit` (unconditional fix). `NEXTPNR_CRIT_WEIGHT`, `NEXTPNR_SHARE_EXP`, `NEXTPNR_LOG_CRIT_GAP` — all default-off. |

### am01 repo

| commit | what |
|---|---|
| `833c1ac` | `.gitattributes`: `*.py text eol=lf` — CRLF shebang broke `make_bram_timing.py` exactly as it had broken `*.sh` |
| `3fd1d0a` | `make_bram_timing.py --vivado-sdf` — real Kintex-7 timing instead of artix7 proxy |
| `1165fb0` | BRAM floorplan scripts (block + striped) |
| `c21b7a0` | Vivado query scripts (SDF extraction, timing reference) |
| `2e066b1` | two upstream issue drafts; control-set writeup marked RESOLVED |

---

## What is PROVEN

1. **447 → 0 unrouted, reproducible.** Striped BRAM floorplan, 4/4 seeds, ~22 min.
2. **Block RAM was invisible to STA.** Fixing it moved `clk_h` 135.32 → 65.19 MHz.
   Every timing number recorded before this is void.
3. **Real BRAM timing is 2.080 ns** (Vivado SDF, xc7k325t-1, slow corner, identical
   across all 1680 arcs). The artix7 proxy was 18% pessimistic.
4. **Our logic delay matches Vivado within 4%** (2.1 vs 2.186 ns) — so the BRAM
   number is right and the gap is entirely **net delay** (13 ns vs 3.787 ns).
5. **The critical path is one net spanning 375 tiles**, (193,5) → (86,273),
   contributing 11.0 of 13.1 ns. The router is using long lines and doing well
   with an impossible placement.
6. **All 420 sbox ROMs reach the bitstream bit-exact** — verified by decoding
   every `RAMB18` site from the FASM and matching all 1024 words against
   `encrypt.v`. 420 matched, 0 unmatched.
7. **Two genuine upstream nextpnr bugs**, both from 2020 and both absent from
   upstream's own timing meta-issue #470.

---

## What is REFUTED (do not re-explore)

| hypothesis | verdict |
|---|---|
| Wire reservations block the failing arcs | `reserved_net == self` on every sample |
| Rigid route tree / same-pip re-entry | `same_net_diff_pip = 0` everywhere |
| A* heuristic degenerates to Dijkstra | g/h ratio 0.1–2.8 across 206 samples, no drift |
| Serial thread bin dominates runtime | 4–9% of nets, not "most" |
| Failed-net re-route pass is the bottleneck | literally 0 ms |
| `arch_place.cc` frozen-tile bypass | inert in a pure HeAP flow |
| Bigger search budget fixes it | 2M: unrouted→0 but 404 overused, thrashing |
| Legaliser occupancy penalty (cell count) | **worse** — 47 unrouted vs ~10 |
| More columns-per-round tuning | 2 and 3 both worse than 7 |
| Better seed exists | seed 7 was the outlier; 1/3/11 all ~1500+ |
| Raising `--placer-heap-alpha` | monotonically worse (0.2/0.4/0.8) |
| HeAP discards its own best placement | it does save/restore correctly |
| prjxray pip delays are a stub | real and well-calibrated |
| RWRoute / DREAMPlaceFPGA usable here | both UltraScale+ only |

---

## What is UNTESTED (the actual to-do list)

### Router knobs — built, never run
```
NEXTPNR_CRIT_WEIGHT=0.4..0.6   criticality weights delay vs congestion
NEXTPNR_SHARE_EXP=2            RWRoute-style criticality-aware sharing
NEXTPNR_ISO_HEURISTIC=1        isotropic y coefficients
NEXTPNR_LOG_CRIT_GAP=1         quantify routed-vs-predicted delay
NEXTPNR_ASTAR_RELAX=1          + _EPS: cost relaxation (costly: ~22 min/iter)
```
**Caveat that may invalidate all of them:** criticality during negotiation comes
from `predictDelay` — a Manhattan estimate of the *placement*, because router2
never binds wires until `overused == 0`. The timing feedback loop is **open**.
Run `LOG_CRIT_GAP` first; if routed/predicted is far from 1.0, these knobs are
weighting fiction.

### The decisive experiment not yet run
**Vivado placement + nextpnr routing**, via `xilinx/java/json2dcp.java`:
```
yosys → JSON → nextpnr --pack-only → json2dcp → Vivado place_design
     → extract placement → BEL attrs → nextpnr route
```
Not a shippable open flow, but it separates "router cost model is wrong" from
"placement is unroutable-and-slow" in a single run. That ambiguity has driven
most of this session.

### Correctness issues found by review, NOT yet fixed
1. **A bitstream with zero S-box data sits in `out_nm1/`** — 270 KB truncated
   FASM, yet an 11.4 MB `.bit` indistinguishable by size from a good one. Delete it.
2. **`build.sh` defaults `FREQ=50`** while the board runs at 133.33 — reachable
   from the documented command line. Silent wrong-hashes path.
3. **No build gates**: `SKIP_FAILED_ARCS`, `FAIL at`, and BRAM line count should
   all fail the build. `arch.cc:2187` returns `result = true` unconditionally for
   router2, so the router's outcome is discarded entirely.
4. **Unrouted LUT-input arcs silently rewrite truth tables.** `fixupRouting` +
   `get_lut_init` drop inputs whose permutation pip was never bound, so the LUT
   computes a cofactor. Not "missing wires" — *wrong logic*, with no warning.
5. **Reset race** (`odocrypt_gpio_wrapper.v`): `req_toggle_bus` resets in the bus
   domain while the clk_h receiver has no reset, injecting a spurious request that
   shifts the header one 32-bit word. Mines happily, every result wrong.
6. **No pull-ups on `gpio_wr_n`/`gpio_rd_n`** — float between config and CM4 GPIO
   setup; two consecutive samples fire a bogus write.
7. **`clk_h` domain has no reset at all** — SW2 resets only the bus front end.
8. **`set_clock_groups`/`ASYNC_REG` are silently ignored** by nextpnr's XDC parser
   (only `set_property`, `create_clock`, `set_multicycle_path` are understood).

### Open questions
- Does `dfflegalize -minsrst/-mince 999999999` still earn its keep? The bug it
  worked around was fixed in `bf78fccf`. Costs LUTs if obsolete. **Deliberately
  not tested this session.**
- `NUM_MINERS=2` needs 840/890 BRAMs = 94% utilisation. Vivado does it; the
  striping strategy has almost no room to distribute egress at that density.
- Is ~65 MHz recoverable by router work, or is the mux2 path the only route to
  133.33? Depends on the Vivado-placement experiment.

---

## Reusable artifacts

| file | purpose |
|---|---|
| `floorplan_stripe.py` | parameterised BRAM floorplan, `--cols-per-round`, handles NUM_MINERS>1 |
| `seed_sweep.sh` | v26 config, only `--seed` varies; documents why NOT to pass `--placer-heap-beta` |
| `vivado_bram_sdf.tcl` | extract real device timing |
| `vivado_timing_check.tcl` | the Vivado reference number |
| `vivado_bram_timing.sdf` | 216 MB, 840 cells — keep, regenerating costs a Vivado session |
| `upstream-issue-{1,2}-*.md` | ready to file, need `gh auth login` |

---

## Method note

The two changes that actually moved the number (requeue, congestion policy) were
both found by **instrumenting the router and reading counters**. Almost every
hypothesis reached by reasoning about the source was refuted by measurement —
including several I was confident about.

The recurring failure mode was changing the measuring apparatus and then comparing
across the change: the `--placer-heap-beta` fix silently altered every subsequent
run, a broken `settings.count()` guard changed three placer parameters while I
checked one, and four instrumentation counters measured something other than what
their names implied.

Verify the whole output against a known-good reference before trusting any
comparison.
