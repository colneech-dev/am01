# Audit: what is built, what was tested, what is broken

Produced 2026-08-24 by reading the trees, **not** from session memory. Every
claim below has a file:line or a reproducible command behind it.

Motivation: three separate things were reported during this work as evidence
and turned out to be measuring nothing (`unrouted=0`, the net-delay calibration
CSV, the congestion map). The common failure was treating "the mechanism exists
and is committed" as equivalent to "the mechanism works". This file exists so
that confusion is not repeated.

## How to regenerate this audit

```bash
# every knob that exists
cd /home/colin/src/nextpnr-xilinx-heatmap
grep -rhon 'getenv("NEXTPNR_[A-Z_0-9]*"' common/ xilinx/ \
  | sed 's/.*getenv("\(NEXTPNR_[A-Z_0-9]*\)".*/\1/' | sort -u

# every knob a run script actually SETS (as opposed to documents)
cd hardware/qmtech-kintex7/openxc7
grep -rhnE '^[^#]*NEXTPNR_[A-Z_0-9]+=' *.sh | grep -oE 'NEXTPNR_[A-Z_0-9]+' | sort -u
```

**Headline: 57 knobs exist. 15 have ever been set by any run script. 42 have
never been exercised at all.**

Note `build.sh` sets **zero** knobs — every knob named in its header is a
comment. `grep -cE '^[^#]*NEXTPNR_[A-Z_0-9]+=' build.sh` returns 0. Appearing
in `build.sh`, `SESSIONS.md` or `TESTS-TO-RUN.md` is documentation, not
evidence of a run.

> **Both grep methods above are fallible — trust artefacts, not scripts.**
>
> - Grepping for the knob NAME false-**positives** on comments. A slower audit
>   run marked `NEXTPNR_CRIT_WEIGHT`, `ROUTER2_MAX_ITER` and `SKIP_FAILED_ARCS`
>   as exercised purely because `build.sh` and a test script mention them in
>   prose.
> - Grepping for `^[^#]*KNOB=` false-**negatives** on indirection.
>   `test_criticality_knobs.sh` sets its knobs by passing name and value to a
>   `run_test` helper, so no literal `NEXTPNR_X=` line exists and the stricter
>   regex misses it entirely.
>
> The reliable test is whether the run produced an **output artefact** — a
> `.pnr.log`, a FASM, a result file. `test_criticality_knobs.sh` has none, so
> its knobs are genuinely unexercised despite being wired up correctly.

---

## 1. Built and never exercised (42)

### 1a. Placement — the area the measurements actually point at

| knob | file:line | note |
|---|---|---|
| `NEXTPNR_CONGESTION_MAP` | `common/placer_heap.cc:1270` | router→placer feedback; was broken end-to-end until 2026-08-24 (§3) |
| `NEXTPNR_CONGESTION_W` | `common/placer_heap.cc:1292` | weight for the above |
| `NEXTPNR_TILE_NETS` | `common/placer_heap.cc:1300` | builds an `unordered_set` per candidate bel **inside the inner scan loop** — runtime hazard, review flagged |
| `NEXTPNR_NET_SHARE_WEIGHT` | `xilinx/arch.cc:944` | legaliser review: pushes the wrong way on this design |
| `NEXTPNR_PLACER_ALPHA` | `xilinx/arch.cc` | alpha only ever reached via defaults |
| `NEXTPNR_PLACER_BETA` | `xilinx/arch.cc` | beta only ever reached via the `--placer-heap-beta` CLI flag |
| `NEXTPNR_SPREAD_SCALE_X` / `_Y` | `xilinx/arch.cc` | never set |
| `NEXTPNR_FRESH_REGION_MARGIN` | `xilinx/arch.cc` | never set |
| `NEXTPNR_EXCLUDE_STAMPED_BBOX` | `xilinx/arch.cc` | never set |

### 1b. Router

| knob | note |
|---|---|
| `NEXTPNR_CRIT_WEIGHT` | exact PathFinder blend, `common/router2.cc:570`. **Documentation only** — named in `build.sh` comments, `SESSIONS.md`, `TESTS-TO-RUN.md`; assigned in no script. Blocked anyway: see §4 `update_route_delays`. |
| `NEXTPNR_SHARE_EXP` | exact RWRoute sharing form, `common/router2.cc:604`. Same status as above. |
| `NEXTPNR_ASTAR_RELAX` (+`_EPS`) | router review rated this the highest-quality unrun knob: `router2.cc:1227` closes a wire on **push**, not pop, so the relaxation branch is provably dead without it |
| `NEXTPNR_BIDIR_HYBRID` (+`_BWD_ITERS`) | review's highest-risk unrun knob — the stitch is the one path that can plausibly create a `bound_nets` cycle |
| `NEXTPNR_GLOBAL_ROUTE` | seeds `hist_cong_cost` from demand/capacity before routing |
| `NEXTPNR_LOG_CRIT_GAP` | pure instrumentation; measures whether criticality is real. Review: "run it first" |
| `NEXTPNR_WHY_BLOCKED` | diagnostic |
| `NEXTPNR_DUMP_CONGESTION` | see §3 — could not fire on a converged run |
| `NEXTPNR_ROUTER2_MAX_ITER` / `_MAX_STALL` | named in `build.sh` comments only |

### 1c. Arch / packing (~22, none ever set)

`ALLOW_CO_5FF_CONTENTION`, `BUFG_CONST_DISCONNECT`, `CARRY_COUNTER_FIX`,
`NO_CARRY_COUNTER_FIX`, `NO_CARRY_O_RELOC`, `CARRY_OMIT_GND_DI`,
`GND_HOLDOUT_FILE`, `GND_NO_RIPUP`, `LOG_CONST_HOLDOUTS`, `PIP_BLACKLIST`,
`PIP_BLACKLIST_TILE`, `GT_CLK_BODGE`, `RX_PLAIN_LVCMOS`, `NO_LONGLINES`,
`FIXEDROUTES_HOOK`, `DUMP_INVALID_TILE`, `DBG_CONSTR`, `DBG_LUTGATE`,
`DBG_SHORTROUTE`.

### 1d. The 15 that HAVE been set, and by what

| knob | set by |
|---|---|
| `ARC_MAX_VISIT`, `ARC_RETRY_BACKOFF`, `ARC_VISIT_ESCALATE`, `CONG_CLAMP`, `CONG_GROWTH`, `DIVERSIFY_RETRY`, `HIST_DECAY`, `REQUEUE_UNROUTED`, `SKIP_FAILED_ARCS` | `seed_sweep.sh` |
| `ISO_HEURISTIC` | `run_region_experiment.sh`, `run_queued_after_routes.sh` |
| `CRIT_DIST_EXP` | `run_crit_dist.sh`, `screen_placer_knobs.sh`, `screen_linear_delay.sh` |
| `HPWL_SCALE_FIX` | `run_hpwlfix.sh`, `screen_placer_knobs.sh` |
| `LINEAR_DELAY` | `screen_linear_delay.sh` |
| `SMALL_BETA` | `screen_placer_knobs.sh` |
| `WIRE_DEMAND` | `screen_wire_demand.sh` |

---

## 2. Built and FAILED — measured, not assumed

Screen figures are the SA refinement's final `timing cost` / `wirelen`,
placement-only. Baseline 13045 / 4260448.

| thing | measurement | verdict |
|---|---|---|
| `NEXTPNR_LINEAR_DELAY=1` | timing cost **22522** (73% worse than baseline) | **refuted.** Built on a finding the timing review later retracted; a uniform delay scale is provably invisible to criticality (`timing.cc:678-680`) |
| `NEXTPNR_CRIT_DIST_EXP=1.0` | best screen (**8685**), then routing stalled at `overused≈1595` at iter 31 where baseline was at **6** | **refuted on the routed metric.** Buys short critical nets by lengthening everything else |
| `NEXTPNR_CRIT_DIST_EXP=0.5` | 16561 | worse than baseline |
| `--placer-heap-beta 0.9` | spread WL 3.2M → legal WL 5.86M (+82%), 48× slower | refuted; strict legalisation is not wirelength-aware |
| `--placer-heap-beta 0.25` | spread WL worse than 0.4, 4× slower | refuted; **0.400 confirmed correct from both directions** |
| post-place repair as suspect | max move **7 tiles**, r>8 bucket empty, 75% move 0 | **exonerated.** Cannot produce a 132-row separation |
| region / `--floorplan-hierarchy` | worse than no regions in every geometry tried | refuted (earlier sessions) |
| `NEXTPNR_SMALL_BETA=0.4` | 11646 (modest screen gain) | unrouted, unresolved |

---

## 2a. Complete placer-knob screen (2026-08-24)

Placement-only (`--no-route`), SA refinement final `timing cost` / `wirelen`,
same netlist `out_nm1_nosr/am01_qmtech_top_v68.json` throughout. Produced by
`screen_placer_knobs.sh`, `screen_linear_delay.sh`, `screen_wire_demand.sh`.

**These rank candidates. They decide nothing.** `CRIT_DIST_EXP=1.0` tops this
table and then failed to route, sitting at `overused≈1595` at iteration 31 where
the baseline was at 6. Only a routed number is a result.

| config | timing cost | wirelen | note |
|---|---|---|---|
| `NEXTPNR_CRIT_DIST_EXP=1.0` | **8685** | 4106478 | best screen, **failed to route** |
| `NEXTPNR_WIRE_DEMAND=1.0` | 10836 | 4180296 | best that also improves both vs baseline; **queued for full route** |
| `NEXTPNR_HPWL_SCALE_FIX=1` | 11299 | **3986156** | best wirelength; **full route in flight** |
| `NEXTPNR_SMALL_BETA=0.4` | 11646 | 4249226 | BRAM density; unrouted |
| `NEXTPNR_WIRE_DEMAND=2.0` | 12894 | 4222197 | threshold too loose |
| *baseline (no knobs)* | *13045* | *4260448* | reference |
| `CRIT_DIST_EXP=1.0 + SMALL_BETA=0.4` | 13600 | 4112566 | worse than either alone |
| `LINEAR_DELAY=1 + CRIT_DIST_EXP=1.0` | 13579 | 4291046 | worse than CDE alone |
| `NEXTPNR_WIRE_DEMAND=0.5` | 16120 | 4207329 | threshold too tight |
| `NEXTPNR_CRIT_DIST_EXP=0.5` | 16561 | 4195033 | half-strength worse than baseline |
| `CRIT_DIST_EXP=1.0 + HPWL_SCALE_FIX=1` | 18027 | 4066191 | worse than either alone |
| `NEXTPNR_LINEAR_DELAY=1` | 22522 | 4198320 | **worst of all**; refuted |

Two patterns hold across the whole set:

1. **Every combination is worse than its better half alone.** `CDE+HPWL_FIX`
   18027 against 8685 and 11299; `CDE+SMALL_BETA` 13600 against 8685. These
   knobs interact destructively, so do not assume additivity when tuning.
2. **`WIRE_DEMAND` has a real optimum at 1.0**, not a monotonic trend — 2.0 is
   too loose for any tile to trip, 0.5 tight enough that the spreader thins the
   whole die.

> **Correction:** `wd05` was reported as 13977 in conversation. That was read
> mid-run before SA converged; the final value is **16120**. Ranking unchanged.

---

## 3. Built and BROKEN

| defect | file:line | status |
|---|---|---|
| **Congestion feedback loop never functioned.** Dump was nested inside `if (getenv("NEXTPNR_SKIP_FAILED_ARCS"))` in the abort branch, so a converged run wrote nothing. And the writer accumulates `float` while the reader used `atoi()` — fractional → 0, `1.23457e+06` → 1, collapsing the map to a 0/1 mask. | writer `common/router2.cc:2340`; reader `common/placer_heap.cc:1285` | **fixed 2026-08-24**, still unrun |
| **`unrouted_arcs` counted only under `REQUEUE_UNROUTED`, printed always.** No run script sets that flag, so **every `unrouted=0` ever logged is vacuous**, including the 89.30 MHz baseline's. It also feeds the stall detector, which therefore degenerated to `overused_wires` alone. | `common/router2.cc:1626-1649` vs `:2282` | **fixed 2026-08-24** |
| **BRAM bypasses `beta` entirely.** `bels.at(t) < 4` sends BRAM tiles (2 RAMB18E1 bels) down the strict-overflow branch, so block RAM has a 100% density target at every beta. 420 of 890 used. | `common/placer_heap.cc:1480-1492` | env-gated fix `NEXTPNR_SMALL_BETA` added, unrun |
| **`id_CARRY8` in the xc7 placement cell group.** xc7 packing only ever creates `CARRY4` (`xilinx/pack_carry_xc7.cc:75`), so carry chains are excluded from the LUT/FF group and spread as an isolated type. | `xilinx/arch.cc:953` | **unfixed** — real, but only 100 cells in this design |
| **`getRouteBoundingBox` src/dst copy-paste.** Guard tests `src`, body indexes `dst` throughout, so net bounding boxes can be under-sized on the source side. Feeds `nd.bb`, the `hit_test_pip` filter and MT bin assignment. Inherited from `401f818c`. | `xilinx/arch.cc:804-805` | **unfixed** |
| **Criticality normalised per clock domain.** `bus_clk`'s worst path (257 MHz, passing) gets criticality 1.0, identical to failing `clk_h`. The placer cannot tell which domain matters. | `common/timing.cc:678-680` | **unfixed** |
| **`getWireDelay` returns 0 on xc7**, and 568/600 INT_L wires have null R/C, so the `driving_pip_loc` RC term is dead code for 88% of routing. Routed delay is pip-count × per-class constants. | `xilinx/arch.h:1059-1064`, `:1436-1456` | **unfixed** (calibration says the distance term is nonetheless adequate — see §5) |
| **No `create_generated_clock` in the XDC reader.** Only `set_property`, `create_clock`, `set_multicycle_path` are handled; MMCM-derived clocks are never derived. | `xilinx/xdc.cc:184,208,245` | unfixed; harmless here only because `--freq` coincides at 7.5 ns |
| **Chipdb is stale and unverified.** Built 2026-08-13 with `bbasm` from a *different tree* (`nextpnr-xilinx-head`), before the Aug 21 timing work. `grep chip_info->version xilinx/arch.cc` returns nothing — there is no revision check. | `chipdb.log`, `build-chipdb.sh:23-30` | **unfixed** |
| **Threadsafety writeup's banner is wrong.** It claims bug 2 was fixed upstream by `c42f87b3`; that commit guarded only the A* loops. The merge-check walk is still unguarded. | `nextpnr-xilinx-router2-threadsafety-bug.md:8-12`; code at `common/router2.cc:1031-1055` | **unfixed** |
| **Unguarded walks over a net's routing under MT.** `ripup_arc` (`:472`) and `check_arc_routing` (`:639`) follow `bound_nets` with no `thread_test_wire`, and `BoundNets` is now a `std::vector` — a concurrent insert/erase reallocates while another thread holds a reference. | `common/router2.cc:472,639,1031` | **unfixed** |
| **`NEXTPNR_SKIP_FAILED_ARCS` can ship an incomplete netlist silently.** `bind_and_check` returns true for `!ad.routed` without incrementing `arch_fail`; `xilinx/arch.cc:2203` hardcodes `result = true`. | `common/router2.cc:1692`, `xilinx/arch.cc:2203,2216` | **unfixed** |
| **`NEXTPNR_ARC_MAX_VISIT` defaults to 0 = unbounded** on the no-BB retry, so one iteration can drain a 1.4M-wire graph. This is the mechanism behind the run that had to be killed. | `common/router2.cc:1133,1141-1144` | **unfixed** |

---

## 4. Proposed, never built

| item | evidence | note |
|---|---|---|
| **`router2_mt_partition.proposed.cc`** | 13,660 bytes in this directory; `grep -rn 'MT_DEEP\|deep_ok'` over `common/` and `xilinx/` returns **nothing** | a design document with code in it. Referenced only by `README.md` and the threadsafety writeup |
| **`update_route_delays`** | exists upstream (`nextpnr-upstream/common/route/router2.cc:1679-1695`), absent here | feeds real routed delay back into criticality each iteration. **Without it, criticality during negotiation is `predictDelay` — a placement estimate — so `CRIT_WEIGHT`/`SHARE_EXP` can only amplify a wrong signal** |
| **Register replication for `crypt.progress[1]`** | `encrypt.v:15330`, fanout **644**, 1620 routing nodes, 15.104 ns, sole owner of all three worst Vivado paths | strongest open lead. `predictDelay` has no fanout term (`xilinx/arch.cc:831-862`) and HeAP divides weight by `users.size()` (`placer_heap.cc:812`), so the net that owns the failure is weighted at 1/644 |
| **Wirelength-aware legalisation** | `legalise_placement_strict` scores `input_len` over **input drivers only** (`placer_heap.cc:1220-1232`) | a cell's fanout exerts zero force, so a BRAM is free to drift away from every LUT that reads it. No displacement term, radius capped only at die size |
| **Post-legalisation detailed placement** | `common/place_common.cc:102-110` already computes true HPWL at a candidate bel | every comparable tool (VPR, UTPlaceF, elfPlace, DREAMPlaceFPGA) has this stage; nextpnr-xilinx has none |
| **VPR-style measured delay table** | `vpr/src/place/place_delay_model.*` | routes samples to build a (dx,dy) lookup. Timing review's own conclusion: **low value here**, since the analytic distance model measured within 10% of empirical |

---

## 5. Evidence that was measuring nothing

Recorded because each was cited as support for a conclusion.

| artefact | reality |
|---|---|
| `unrouted=0` in every log | counter never incremented (§3). What genuinely converged is `overused=0` |
| `vivado_net_delay_calib.csv` | **37 bytes — header row, no data.** Its `.tcl` targeted a DCP that does not exist. Superseded by `vivado_net_delay_calib5.csv` (20,000 rows) |
| `cong_map_iter1.csv` | could only have come from a `SKIP_FAILED_ARCS` run, so it describes a **failed** route's congestion. The "congestion is diffuse — 28% of tiles" analysis characterises that failed route, not the converged design |
| "delay model error grows with distance, sign change at ~13 tiles" | **retracted by its own author.** Extrapolated from a single data point. Measured over 20,000 net delays the ratio is **0.78×, flat, no distance trend**. A uniform factor is invisible to criticality |
| post-place `Max frequency` | diverges from routed by 29 MHz on the baseline (118.20 → 89.30). Never a result |

---

## 6. What is actually established

| claim | basis |
|---|---|
| **Placement owns the gap, not routing** | nextpnr placement + Vivado router = 63.55 MHz, *below* our own router's 89.30 on the identical placement (68266/68450 cells LOC-fixed) |
| Vivado ceiling on this netlist | 158.81 MHz, Vivado place + Vivado route |
| Our baseline | 89.30 MHz routed, `overused=0` at iter 45 |
| `beta=0.400` is correct | 0.25 and 0.9 both measured worse |
| Post-place repair is not the problem | max move 7 tiles |
| The design's worst net | `crypt.progress[1]`, fanout 644 |
| BRAM utilisation | 420 RAMB18E1 of 890 (47%) |

---

# 7. What to do, in order

Ordered by (value x confidence) / effort, with dependencies made explicit.
Anything that can invalidate later work comes first. **Every gate is a ROUTED
number** — the post-place estimate diverged 118.20 -> 89.30 on the baseline and
must never be reported as a result.

## Stage A — finish what is already running (cost: zero, just wait)

1. **`HPWL_SCALE_FIX` full route.** In flight. The only pending routed number.
   Gate: does `overused` track the baseline's trajectory (single digits by
   iter 25)? If it sits in the hundreds at iter 30 it will not converge, as
   `CRIT_DIST_EXP` did not. Compare routed Fmax against **89.30**.
2. **`WIRE_DEMAND` screen at 2.0 / 1.0 / 0.5, then FULL-ROUTE the best.**
   First ever exercise of in-placement congestion estimation. Read
   **wirelength** as the routability proxy, not timing cost — that is the
   specific lesson from `CRIT_DIST_EXP`, which won on timing cost and then
   failed to route.

   **Promoted 2026-08-24 on evidence.** Full screen table in §2a. Summary,
   against baseline 13045 / 4260448:

   | threshold | timing cost | wirelen |
   |---|---|---|
   | `WIRE_DEMAND=2.0` | 12894 | 4222197 |
   | **`WIRE_DEMAND=1.0`** | **10836** | **4180296** |
   | `WIRE_DEMAND=0.5` | 16120 | 4207329 |

   A real optimum at 1.0, not a monotonic trend: 2.0 is too loose for any tile
   to trip, 0.5 tight enough that the spreader thins the whole die. It is also
   the only candidate that is congestion-aware by construction, so unlike
   `CRIT_DIST_EXP` it should improve routability rather than trade it away.
   **Queued via `queue_wire_demand.sh`**, which waits on the `hpwlfix` FASM
   (an artefact, not `pgrep` — see the script header for why).

## Stage B — free measurements that can invalidate later work (hours, no code)

3. **`NEXTPNR_LOG_CRIT_GAP=1`, one run.** Measures the routed/predicted delay
   ratio per iteration. If criticality during negotiation is fiction, then
   items 12 and 13 are weighting noise and must not be attempted. This is the
   cheapest experiment in the whole list and it gates two of the larger ones.

   > **The runner already exists: `test_criticality_knobs.sh`.** Written
   > 2026-08-23, functional, **never run**, and was untracked until now. It
   > covers T6 (`LOG_CRIT_GAP`), T7 (`CRIT_WEIGHT` 0.4/0.6) and T8
   > (`SHARE_EXP` 1/2/3).
   >
   > **Run T6 ONLY at first.** T7 and T8 are blocked on item 11
   > (`update_route_delays`) — until routed delay feeds back into criticality,
   > both knobs multiply a placement estimate and can only amplify a wrong
   > signal. T6 is precisely the measurement that establishes whether that is
   > the case, so running all three at once would spend hours on two tests
   > whose validity the first one decides.
4. **Read the existing `thread bins:` / `phase ms:` lines** already emitted in
   every log. If `refail_nets` dominates, the MT partitioning work in
   `router2_mt_partition.proposed.cc` buys nothing and should be dropped
   rather than built.
5. **Re-derive the congestion characterisation.** `cong_map_iter1.csv` came
   from a failed route (§5). With the §3 fix in place, dump a map from a
   CONVERGED route and redo the diffuse-vs-hotspot analysis. The earlier
   conclusion is unsupported until this is done.

## Stage C — make results trustworthy (small, unblocks everything after)

6. **Rebuild the chipdb from the current tree and add a version check.**
   It was built 2026-08-13 with `bbasm` from a *different* tree, and
   `chip_info->version` is never validated. Every measurement in this file
   rests on it. Low effort, no Fmax effect, but it removes a silent
   correctness risk from all future numbers.
7. **Guard `NEXTPNR_SKIP_FAILED_ARCS`** so it cannot silently emit FASM for a
   design with disconnected sinks (`router2.cc:1692`, `xilinx/arch.cc:2203`).
   Given `QUARANTINED-BITSTREAMS.md` exists, this is worth a hard error.
8. **Default `NEXTPNR_ARC_MAX_VISIT` to a finite value.** Currently 0 =
   unbounded on the no-BB retry; this is the mechanism behind the run that had
   to be killed. One constant.

## Stage D — the strongest open lead (the only item with a large expected gain)

9. **High-fanout driver replication.**

   > ### CORRECTION 2026-08-25 — the 2026-08-24 correction below was itself WRONG
   >
   > I claimed the 644 fanout was a `dfflegalize` artefact absent from the RTL.
   > **It is in the RTL.** `encrypt.v:15317-15329`, the block the `hdlname`
   > attribute named all along:
   >
   > ```verilog
   > always @(posedge clk) begin
   >     if (read)
   >         begin period[0] <= 0;            state[0] <= in;       end
   >     else
   >         begin period[0] <= period[42]+1; state[0] <= next[21]; end
   > ```
   >
   > `state[0]` is **640 bits**, so one `read` bit selects between two 640-bit
   > sources: 640 × LUT3 with `read` on `I2`, plus 2 × `FDRE.R` for `period[0]`
   > and 1 × `SRLC32E.D` for the shift register. That is the measured 643 loads,
   > exactly.
   >
   > I read the module header, the parent module, and the lines *after* this
   > block, and never opened the block itself — despite the sink `hdlname` being
   > literally `encrypt.v:15317.5-15329.8`.
   >
   > **`dfflegalize` is exonerated.** Control case: net bit 67259
   > (`get_block_pulse_h`) has **608 loads, all native `FDRE.CE`, zero LUTs**. It
   > uses hardware pins wherever it legitimately can. There is no Xilinx FF pin
   > that selects between two non-constant data inputs, so the LUT layer is
   > unavoidable and correct.
   >
   > **Item 9a is REFUTED — do not pursue it.** No `dfflegalize` argument,
   > `-family`, pass ordering or `-nosrl` change removes this. `-mince` /
   > `-minsrst` only make it worse.
   >
   > **Item 9b (replication) is the ONLY lever, and is confirmed necessary.**
   > The fanout is set by the RTL and survives any cell-mapping change. The
   > 15.104 ns is net delay across 640 sinks, not the ~0.1 ns LUT delay.
   >
   > **A second, larger instance exists:** net bit 1936, fanout **809**, from
   > `keccak800.v:248-258` — the same `if (read) state[0] <= …` idiom. So this
   > needs a **threshold-based pass, not a one-net fix**. Full distribution:
   > 4 nets ≥500 (one is the BUFG clock), 2 in 200-499, 1 in 100-199, 1 in
   > 50-99, 111 in 20-49, out of 76,534 nets. A threshold of F=100 touches
   > 8 nets.
   >
   > **`TESTS-TO-RUN.md` T15's "all FFs already CE=1/R=0" cites the WRONG
   > netlist** — it was measured on `out_nm1_fdreonly/`, built by
   > `synth_fdre_only.ys:40` with `-mince 999999999 -minsrst 999999999`, which
   > forcibly unmaps every CE and sync reset. Real census of the netlist we
   > actually place (`out_nm1_nosr/`): 27,550 FDRE + 57 FDSE, of which **1,162
   > have a real CE** and **420 a real R**. T15 itself is still worth running
   > (recovers ~1,100 CE LUTs and ~420 reset LUTs) but is unrelated to this net.
   >
   > **yosys has no high-fanout replication pass** — confirmed by enumerating
   > every registered pass name. Nearest miss is `extract -mine_max_fanout`, a
   > subcircuit-mining filter. `insbuf` inserts buffers but does not partition
   > loads.

   ---

   *Superseded text from 2026-08-24, kept so the error is auditable:*

   ~~In RTL that signal has **fanout 1**: `encrypt.v:15519` passes it as the
   `read` port of `encrypt_4encrypt_loop`, and inside that module `read` drives
   only `progress[0]` of a pure 172-stage shift register whose sole consumer is
   `assign write = progress[171]`. There is nothing in the source to replicate.~~

   What the netlist actually contains (`scratchpad/fanout_probe.py`):

   ```
   driver: $auto$ff.cc:337:slice$466022   type=FDRE
   net bit 56307 -> 643 loads
     load cell types: {LUT3: 640, FDRE: 2, SRLC32E: 1}
     load ports     : {I2: 640, R: 2, D: 1}
     net name: $auto$ff.cc:337:slice$226003.genblk2...
   ```

   The net is `$auto$ff.cc:337:...`, i.e. **created by yosys `dfflegalize`**,
   which converted a control signal into a LUT-implemented enable/reset and
   broadcast it to 640 LUT3 `I2` pins. The fanout is a synthesis artefact.

   Two consequences:
   - Editing `encrypt.v` or `odo_gen` would change nothing — the fanout is
     created downstream of the source.
   - The fix is **design-independent and upstreamable**: `dfflegalize` runs on
     every design, so any design with a shared enable/reset across a wide
     datapath gets the same broadcast.

   Order of attack:

   **9a. Check whether `dfflegalize` needed to do this at all.** The 640 loads
   are LUT3 `I2` pins implementing an enable that `FDRE` has a native `CE` pin
   for. If that layer is avoidable, it removes a whole logic level from the
   critical path, and **not creating** the net beats replicating it.

   > `TESTS-TO-RUN.md` T15 records "all FFs already CE=1/R=0". **Re-verify that
   > claim before relying on it** — `fanout_probe.py` shows this net driving
   > **2 FDREs on port `R`**, so not every FF has `R=0`. The T15 note is at
   > least incomplete.

   **9b. A `maxfanout`-style yosys pass**: replicate any driver above a fanout
   threshold and partition its loads. Self-contained, well-understood, not
   AM01-specific, and absent from both yosys and nextpnr. Vivado's
   `phys_opt_design` does exactly this, which is consistent with it reaching
   158.81 MHz on our netlist.

   **9b is still required even if 9a lands** — removing the LUT3 layer removes
   a logic level but does not reduce the fanout.

   **Caveat to hold:** 644 fanout is *Vivado's* bottleneck. nextpnr's own
   89.30 MHz run is limited by a different net (BRAM -> LUT,
   `round17.mid[1][158]`). The gain to OUR flow is unmeasured. The
   63.55 -> ~100 MHz figure is INFERRED from the `vivado_path_prize.txt`
   K-table, not measured.
10. **Add a fanout/load term to `predictDelay`.** Without it the placer cannot
    see that a 644-sink net is expensive, so it will recreate this class of
    problem on any design. Low effort, follows directly from item 9.

## Stage E — structural work (large, only after Stage B reports)

11. **Port `update_route_delays`** from upstream
    (`nextpnr-upstream/common/route/router2.cc:1679-1695`). router2 only binds
    wires at final apply, so criticality during negotiation is `predictDelay`
    — a placement estimate. **This is the prerequisite for items 12-13.**
    First step is two lines: `ad.routed_delay` is captured on the const path
    (`:935`) but not on the two main success paths (`:1099`, `:1336`).
12. **Port upstream's `crit_weight` form** rather than tuning our two knobs.
    `crit_weight = max(0.05, 1 - crit^2)` de-weights historical congestion,
    present congestion and sharing in one coefficient, and subsumes both
    `NEXTPNR_CRIT_WEIGHT` and `NEXTPNR_SHARE_EXP`. **Blocked on item 11.**
13. **Criticality-driven selective rip-up.** An arc that is routed and
    uncongested is never revisited regardless of its delay, so on a run that
    converges at iter 45 the last ~40 iterations do nothing for timing.
    RWRoute re-routes the top ~3% most critical every iteration.
    **Blocked on item 11.**
14. **Make legalisation wirelength-aware** (`placer_heap.cc:1220-1232`):
    add a displacement term, score output nets as well as input drivers, and
    apply `hpwl_scale_y`. ~25 lines. Currently a BRAM's readers exert zero
    force on it, which is the shape of nextpnr's own critical path. Note the
    prize is bounded — at `beta=0.4` legalisation costs only +0.5%.
15. **Global rather than per-domain criticality normalisation**
    (`timing.cc:678-680`). `bus_clk` at 257 MHz currently gets criticality 1.0,
    identical to failing `clk_h`, so the placer cannot tell which domain
    matters.

## Stage F — correctness debt (no Fmax effect; do when convenient)

16. **`id_CARRY8` -> `id_CARRY4`** for xc7 (`xilinx/arch.cc:953`). One line,
    guarded on the existing xc7 flag. Only 100 cells here, so measure rather
    than assume a gain.
17. **`getRouteBoundingBox` src/dst copy-paste** (`xilinx/arch.cc:804-805`).
    Guard tests `src`, body indexes `dst`. Feeds `nd.bb`, `hit_test_pip` and
    MT bin assignment.
18. **Guard the unguarded MT walks** over `bound_nets` in `ripup_arc` (`:472`)
    and `check_arc_routing` (`:639`). `BoundNets` is now a `std::vector`, so a
    concurrent insert/erase reallocates under a held reference.
19. **Fix the banner in `nextpnr-xilinx-router2-threadsafety-bug.md:8-12`** —
    it currently tells a future reader the bug is closed when it is not.
20. **`create_generated_clock` in `xdc.cc`.** Harmless today only because
    `--freq` coincides with the MMCM output at 7.5 ns.

## Do NOT do

- **Re-run `NEXTPNR_LINEAR_DELAY` or any uniform delay calibration.**
  Criticality is scale-invariant (`timing.cc:678-680`); a uniform factor
  provably cannot reach the placer. Measured worst of everything tested.
- **Re-sweep `--placer-heap-beta`.** 0.25 and 0.9 both measured worse than
  0.400 from opposite directions.
- **Re-investigate post-place repair.** Max move 7 tiles; it cannot produce
  the observed separations.
- **Build a VPR-style measured delay table.** The analytic distance model
  measured within 10% of empirical over 20,000 net delays; it would also miss
  the fanout problem identically.
- **Build region/floorplan constraints.** Worse than no regions in every
  geometry tried, and strict legalisation punishes them further.
- **Build `router2_mt_partition.proposed.cc`** until item 4 shows that
  `serial_nets`, not `refail_nets`, is the limiter. It is a runtime
  optimisation with no Fmax effect either way.
- **Chase `budget 0.000000`.** The HeAP placer never reads budgets;
  `assign_budget` runs at the first line of `Arch::route()`, after placement.
- **Edit `encrypt.v` or `odo_gen` to fix the 644-fanout net.** The fanout does
  not exist in the RTL — it is manufactured by `dfflegalize` during synthesis
  (§7 item 9). An RTL change would measure no effect.

---

## Plan revision 2 — 2026-08-25, after the budget/seed matrix and T6

### Items REMOVED from the list (settled by measurement, not opinion)

| item | why it is off |
|---|---|
| **All placer knobs** | `CRIT_DIST_EXP`, `WIRE_DEMAND`, `SMALL_BETA`, `HPWL_SCALE_FIX`, `LINEAR_DELAY` — none beats the 89.30 MHz baseline, across arc budgets **200k / 2M / unbounded** and **two seeds**. Only `HPWL_SCALE_FIX` converged at all, at 84.42 MHz |
| **MT partitioner** (`router2_mt_partition.proposed.cc`) | **`refail_nets=0` on every iteration**, and the serial phase is <1% of runtime (44.7 s against 2780+2526 s parallel). It optimises a bottleneck that does not exist. **Delete the proposal** |
| **Item 12** — port upstream `crit_weight` | blocked: see T6 below |
| **Item 13** — criticality-driven selective rip-up | blocked: see T6 below |
| **`NEXTPNR_CRIT_WEIGHT` / `NEXTPNR_SHARE_EXP`** | faithful PathFinder/RWRoute implementations multiplying a signal that is 8–30x wrong. Not worth running until item 11 lands |

### T6 RESULT — criticality during negotiation is fiction

`NEXTPNR_LOG_CRIT_GAP=1`, routed vs predicted delay per arc:

```
iter 1   27697 arcs   mean 29.88   worst 663.09 (routed 99.46 ns vs predicted 0.15 ns)
iter 2   26048 arcs   mean 11.88
iter 3                mean  7.64   (overused had fallen 127623 -> 5894)
```

Congestion fell **22x** between iterations 1 and 3; the delay ratio fell only **4x**
and is still 7.64x. That looks like a **floor**, not congested detours — a
persistent gap independent of congestion. Watch the value at `overused=0`;
that is the number that decides item 11's priority.

Mechanism: router2 binds wires only at final apply, so during negotiation
`net->wires` is empty and `getNetinfoRouteDelay` (`common/nextpnr.cc:303-304`)
falls back to `predictDelay`, a Manhattan estimate of the PLACEMENT.
`get_criticalities` is called inside the negotiation loop (`router2.cc:2195`).

> This does NOT contradict the earlier timing-model retraction. That measured
> `predictDelay` against **final routed** delays on a converged design and found
> 0.78x, flat. This measures it against routes chosen **mid-negotiation**, which
> are heavily detoured. The model describes an idealised direct route well and
> describes what the router is actually doing badly — at exactly the moment the
> router consults it.

### A sixth silently-nonfunctional mechanism

`ad.routed_delay` was assigned **only** on the constant-net path
(`router2.cc:935`) while `ad.routed = true` is set at 936, 1099, 1311, 1336.
Every arc routed by the ordinary forward A* kept its `-1` initialiser, and the
crit-gap loop skips exactly those — so T6 **could never have produced output**.
Fixed at `:1099`; the backward-BFS and bidir-stitch sites are deliberately left
unset because `visit.score` there is not the committed path's delay.

Joins the congestion feedback loop, `unrouted_arcs`, `test_criticality_knobs.sh`,
and the empty calibration CSV. **The recurring defect in this codebase is not
bad code — it is code that was never once executed.**

### Revised order

1. **Item 11 — `update_route_delays`.** Now the highest-value structural item:
   it is the only thing that replaces the estimate with measured routed delay,
   and `routed_delay` now exists to feed it. Unblocks 12 and 13.
2. **Item 9a — is `dfflegalize`'s LUT layer necessary?** Every failure names a
   BRAM-egress net, and the 644-fanout net is a `dfflegalize` artefact.
3. **BRAM egress** — is it a PHYSICAL limit (RAMB18 tile egress wire count) or a
   TOOL limit? This distinction decides whether any placer work is worthwhile at
   all. **New item, ahead of 9b.**
4. **Item 9b — `maxfanout` replication pass.** Still required even if 9a lands:
   removing the LUT layer drops a logic level, not the fanout.
5. Items 10, 14–20 unchanged.

---

## Plan — BRAM output register (RTL pipeline change, ~1.2 ns)

**Status: to do.** Not a tool change and NOT a Vivado-parity item — see the
correction below before anyone treats it as catching up.

All 420 BRAMs are inferred with `DOA_REG=0` / `DOB_REG=0`, because the RTL is a
single registered read (`encrypt.v:3080-3083`):

```verilog
(* ram_style = "block" *) reg [9:0] mem[0:1023];
always @(posedge clk) begin
    a_out <= mem[a_in];
end
```

Our own Vivado-extracted SDF (`make-bram-timing-db.sh`) gives:

```
DOA_REG_U_0  (output register OFF)  (1.353::2.454)
DOA_REG_U_1  (output register ON)   (0.468::0.882)
```

nextpnr uses 2.08 ns (`XC7_BRAM_CLK_TO_DO_NS`), the register-OFF figure.
Enabling it drops clock-to-DO to ~0.88 ns — **~1.2 ns off the critical path**,
where only 0.2 ns is needed to reach 133.33 MHz. On the seed-3 path
(2.1 + 3.8 + 0.2 + 1.3 + 0.2 = 7.7 ns) that lands near 6.5 ns ≈ **153 MHz**.

**Cost:** one extra pipeline stage per S-box read. `encrypt.v`'s 172-stage
`progress` shift register and the round timing must absorb it. `encrypt.v` is
GENERATED, so this belongs in `odo_gen`, not in the generated file.

> **CORRECTION — this is not a Vivado gap.** I initially presented it as the
> next lever to catch Vivado. It is not. `netlist_norename_v68.v` — the netlist
> **Vivado also reads** — carries `DOA_REG(32'd0)` on all 420 BRAMs, so Vivado
> reaches 158.81 MHz with the *same* 2.1 ns clock-to-Q we have. The register is
> an RTL optimisation available equally to both flows.
>
> Same 2.1 ns start in both cases:
>
> | | period | BRAM clk-Q | everything else |
> |---|---|---|---|
> | Vivado 158.81 | 6.30 ns | 2.1 | **4.2 ns** |
> | us 129.79 | 7.70 ns | 2.1 | **5.5 ns** |
>
> So the entire remaining Vivado gap is **1.3 ns of routing and logic**, and
> closing it is a separate problem from this item.

---

## Plan — map the device's timing properly (upstreamable, NOT an Fmax lever)

**Scope check first: three of the four layers already exist.**

| layer | state | source |
|---|---|---|
| routing graph (tiles/wires/pips) | complete | prjxray-db |
| bitstream encoding (FASM bits) | complete | prjxray fuzzing |
| cell timing | 29 SDF files, but **kintex7 shipped none** — we generated BRAM ourselves | Vivado `write_sdf` |
| **wire R/C** | **32 of 600 INT_L wires = 5.3%** | **missing** |

So the gap is one thing: **interconnect wire resistance and capacitance**. Pip
delays are largely present (~57% of INT_L pips carry non-zero delay). Wires are
not, which is why `getWireDelay` returns 0 on xc7 (`xilinx/arch.h:1059`) and
routed delay collapses to pip-count x per-class constants.

### What Vivado will and will not give

Checked directly in the 2026.1 install:

- **No `.speed` files exist** in this version.
- `public/liberty/kintex7.lib` (9.4 MB, plain text) carries timing
  **topology only** — `timing_type` and `related_pin`, no `cell_rise` /
  `intrinsic_rise` values.
- `kintex7_pt.lib` has 61 "values", all `default_intrinsic_rise : 0.0` or
  placeholder `1.0`.
- `kintex7.rtd` is **binary/obfuscated** (header `XlxV64EB`).

The real numbers are only obtainable through Vivado's own reporting.

### What AMD publishes

**DS182** (*Kintex-7 DC and AC Switching Characteristics*) gives speed-grade
cell timing for our `-1` part — free, citable, public. It does **not** publish
per-pip or per-wire routing delays, nor bitstream encoding. Those two are what a
chipdb fundamentally is, which is why prjxray exists.

### Build plan

1. **Cell timing — solved method, ~1 day.** Generalise `make-bram-timing-db.sh`:
   instantiate every primitive, `write_sdf`, parse `IOPATH`. Proven — it
   produced the 216 MB BRAM SDF and `XC7_BRAM_CLK_TO_DO_NS = 2.08`.
   Immediate target: `xilinx/arch.cc:2497` and `:2515` are both
   `delay.delay = 200; // FIXME` — every LUT delay in the flow is a hardcoded
   200 ps.
2. **Wire R/C — an inverse fit, days not months.** The values are locked in the
   binary `.rtd`, so fit rather than read: take routed nets with known pip
   sequences, subtract known pip delays, attribute the residual to wire types.
   **`vivado_net_delay_calib5.csv` already holds 20,000 such samples**, and the
   unknowns are ~24 segment classes (EE2/EE4/HEX/LONG...), not 600 individual
   wires — heavily over-determined least squares.
3. Feed both into the chipdb via `bbaexport.py`, rebuilding with `bbasm` from
   the same tree (see `build-chipdb.sh`'s revision-lock warning).

### Expected value — low for us, real for the project

**This will not close the Fmax gap, and should not be sold as if it might.**
The timing review measured `predictDelay` against those same 20,000 Vivado
delays at **0.78x, flat, no distance trend**, within 10% at the critical span.
Criticality is scale-invariant (`common/timing.cc:678-680`), so a uniform
correction provably cannot reach the placer at all. Our critical path is
2.1 ns BRAM + 7.4 ns net + 0.2 ns LUT — better cell numbers move ~0.05 ns on
11 ns.

Where it does pay:
- **Vendor-traceable timing.** "93.28 MHz" is currently self-consistent, not
  backed by silicon-measured data. For anything shipping, that matters.
- **openXC7 generally.** kintex7 having zero upstream timing data affects every
  user of this part. Genuinely upstreamable, unlike most local patches here.
- Any future design where logic rather than routing dominates.

---

## Parked — upstream contribution (not on the Fmax path)

**yosys#6144 has a maintainer reply (widlarizer, 2026-08-24).** `hdlname` is in
scope for their `src` attribute-transfer work; ABC is confirmed lossy and they
plan to route around it via `abc9 &verify` rather than through it. Their
in-flight PR **#5902** is a draft, stacked on #5804, three months stale.

Consequence: **do not push `hdlname_recover` upstream** — it is a name
heuristic against an in-progress structural fix, and PR #6145 was already
correctly retracted. Keep it local; `--floorplan-hierarchy` depends on it.

What we can offer instead is **data, not code**: a real 70k-cell benchmark, the
quantified failure modes (14438 names rejected vs 5709 accepted before the fix),
and a measured negative result on ABC propagation that supports their position.

Full notes, the maintainer quote, and the pre-posting checklist are in
**`upstream-issue-3-yosys-hdlname-loss.md`** under "STATUS 2026-08-24".
**Nothing is to be posted without explicit approval** — it is public, permanent
and under the user's identity.

---

## Ordering changes since first draft

Kept so the reasoning is auditable rather than silently rewritten.

| change | why |
|---|---|
| item 9 recast from an RTL edit to a **tool fix**, split 9a/9b | `fanout_probe.py` showed the 644 fanout is created by `dfflegalize`; RTL fanout is 1 |
| 9a (`dfflegalize` necessity) **moved ahead of** 9b (replication pass) | cheap, and if the LUT3 layer is avoidable the net is never created |
| `WIRE_DEMAND` promoted from screen curiosity to **next full route** | `WIRE_DEMAND=1.0` is the first config to beat baseline on timing cost *and* wirelength |
| T15's "all FFs already CE=1/R=0" flagged as **unverified** | contradicted by the probe: 2 FDREs take the net on port `R` |

---

## BRAM output register (DOA_REG/DOB_REG) -- resolved 2026-08-28

### The claim

7-series block RAM has an optional output register. The Vivado-extracted SDF
(`make-bram-timing-db.sh`) prices it:

| config | clock-to-DO |
|---|---|
| `DOA_REG_U_0` (off) | 1.353 :: **2.454** ns |
| `DOA_REG_U_1` (on)  | 0.468 :: **0.882** ns |

~1.6 ns, on a critical path that spends 2.1 ns of a 7.7 ns period in exactly
that arc. Only 0.2 ns is needed to reach 133.33 MHz.

### Why the first attempt failed, and what was actually wrong

`odo_gen --bram-out-reg` (commit `3e82a3b`) emits the two-register S-box that
UG901 documents for registered-output inference. Synthesis put the second stage
in **fabric flip-flops**, leaving `DOA_REG=0` on 418 of 420 BRAMs.

Three successive theories, only the last correct:

1. ~~"Vivado does this by default and we don't"~~ **WRONG.**
   `netlist_norename_v68.v` carries `DOA_REG(32'd0)` on all 420 BRAMs and
   Vivado reads that same netlist. Vivado reaches 158.81 MHz *without* the
   output register. This is an optimisation available to both flows, not a
   parity gap.
2. ~~"`--bram-out-reg` inflates BRAM count 421 -> 441"~~ **WRONG.**
   Recounted from the JSON: **420 -> 420, delta 0.** The earlier figure was a
   miscount. The transform costs no block RAM.
3. **`brams_xc6v_map.v` hardcodes it.** Lines 52-53 and 213-214 emit
   `.DOA_REG(0)` / `.DOB_REG(0)`, and `synth_xilinx.cc:519` selects that map for
   `family == "xc7"`.

### This is a yosys limitation, and it is structural

Not a missing line in one file:

* The modern `memory_libmap` infrastructure that xc7 uses **has no
  output-register concept at all** -- `memlib.cc` has no keyword for it.
* The one `make_outreg` keyword in the tree belongs to the **old** `memory_bram`
  pass, and `memory_bram.cc:1300` documents it as adding *"external
  flip-flops"* -- the fabric flops we are trying to eliminate.

**Consequence: no RTL coding style can reach `DOA_REG=1` through inference.**
Restructuring the template ("option 1") is refuted, not merely untried. Every
openXC7 user on any 7-series part is leaving ~1.6 ns of BRAM clock-to-Q
unavailable.

### Everything downstream already supports it

The gap is *only* in synthesis:

| stage | status | evidence |
|---|---|---|
| prjxray bitstream feature | present | `kintex7/segbits_bram_l.db`: `BRAM_L.RAMB18_Y0.DOA_REG 27_69` |
| nextpnr FASM emission | present | `fasm.cc:2291` `write_bit("DOA_REG", ...)` |
| nextpnr timing model | present | `arch.cc:2640` selects the faster clock-to-Q, so the win appears in reported Fmax, not only on silicon |
| yosys | **absent** | above |

### The fix: `absorb_bram_outreg.py`

Attach the register **after mapping**, on the JSON netlist. Delete the fabric
flop and turn the BRAM's own register on:

```
BRAM.DO --netX--> FDRE.D    FDRE.Q --netY-->     (before)
BRAM.DO --netY-->                               (after, DOA_REG=1)
```

Guarded: a side is transformed only if every data bit drives exactly one load,
that load is an `FDRE.D`, nothing escapes to a top-level port, and the flops
share the BRAM's clock with `CE=1`/`R=0`. Refusing is always safe. The
correctness crux is the single-load test -- a second load would still need the
*unregistered* value, which no longer exists once the register is on.

Measured on `am01_qmtech_top_outreg.json`:

| | |
|---|---|
| BRAM sides registered | **840 of 840** (100%) |
| flip-flops removed | **8400** |
| cells | 79812 -> **71412** (baseline 70071, so +1341) |
| absorbed flop control | uniformly `FDRE`, `CE=const 1`, `R=const 0`, `INIT=x` |

### Verification, and its honest limits

`verify_absorb_outreg.py` -- **PASS**: BRAM set unchanged, 8400 deletions all
`FDRE`, every registered side has `REGCE=1`/`RSTREG=0`, all 8400 rewired bits
trace to the correct flop `Q`, no net gained a second driver, **0 non-BRAM cells
modified**.

**Formal equivalence is NOT available here**, unlike the fanout transform's
`equiv_replication.ys`. `RAMB18E1` in yosys's `cells_sim.v` is a timing-only
shell: it declares `DOA_REG` and carries a specify block with the 2454/882
numbers, but has **no `always`/`assign` body**. With no behavioural BRAM model
there is nothing for a SAT solver to reason about. So correctness rests on two
halves: `tb_outreg_equiv.v` for the extra pipeline stage at RTL, and the
structural check above for the rewiring.

### Throughput is NOT lost (checked, because it would have been fatal)

Rounds go 2 -> 3 cycles, so latency grows 171 -> 252. That would be worth
nothing if it raised the initiation interval -- a 50% throughput loss needs a
50% Fmax gain just to break even.

It does not. `keccak800.v:188` defines `THROUGHPUT` as **clocks per hash**,
fixed at 4 by `miner.v:18`, and `write` is self-reported by the core via
`progress[latency-1]`. The deeper pipeline simply holds more work in flight.
**Hashrate is proportional to Fmax; latency does not enter.**

The generator handled the interleaving on its own: `extra_delay` moved 1 -> 0 so
`gcd(4, 3*21+0) = 1` still holds, leaving `state[]` at 21 stages. Note `state[]`
counts **round stages, not clocks**, which is why its depth correctly stays
`unrolling+extra_delay` while only `period[]` scales with `RoundCycles()`.

### Status

* `absorb_bram_outreg.py` -- built, structurally verified
* `verify_absorb_outreg.py` -- built, passing
* `build.sh` -- gained `BRAM_OUTREG=1` (opt-in) and `REUSE_JSON=<path>`
  (skip the ~20 min synthesis when only re-routing)
* `run_cfg.sh` -- gained `SEED=`, which it could not pass before; seed spread on
  this design is ~22 MHz, so an unpinned comparison measures mostly noise
* **route in flight**: tag `outregs3`, y-base 40, `CRIT_DIST=1.0`, seed 3 --
  the exact config behind the 129.79 MHz best, so the delta is attributable
* `tb_outreg_equiv.v` -- still running, independent confirmation of the RTL

### Upstream

A `memory_libmap`-era output-register capability, or a Xilinx-specific
post-mapping absorption pass, would be a genuine yosys contribution:
`absorb_bram_outreg.py` is the working prototype of the latter. **Do not file
until the route confirms a real Fmax gain** -- the argument for upstreaming is
the measurement, not the mechanism.

---

## build.sh place & route was broken for two days -- 2026-08-28

### The defect

```bash
NEXTPNR_ARC_MAX_VISIT="${...:-2000000}" \
${CRIT_DIST:+NEXTPNR_CRIT_DIST_EXP="$CRIT_DIST"} \
"$NEXTPNR" ...
```

Bash recognises `NAME=VALUE` assignment prefixes at **parse** time, before
expansion. A prefix that only becomes `NAME=VALUE` *after* expanding is not an
assignment -- it is taken as the command name:

```
build.sh: line 310: NEXTPNR_CRIT_DIST_EXP=1.0: command not found
```

`CRIT_DIST` defaults to `1.0`, so this fired on **every** `build.sh` run.
Introduced by `fc33171` (2026-08-26), "fold the 93.28 MHz configuration into
build.sh". Fixed by using `env`, which takes the expanded words as its own
arguments. `run_cfg.sh` was never affected because it has always used `env`.

### How many measurements were invalidated: ZERO

Checked, not assumed. Two independent reasons:

1. **The failure is loud and total.** `set -euo pipefail` turns exit 127 into an
   immediate abort. No FASM, no bitstream, no Fmax line. It cannot yield a
   wrong number, only no number.
2. **Nothing went through build.sh in the window.** `build.sh` writes the
   untagged `am01_qmtech_top.pnr.log`; `run_cfg.sh` writes tagged
   `am01_qmtech_top_<tag>.pnr.log`. Every untagged route log predates the bug
   (five on 15-16 Aug, one on 23 Aug), as do all untagged FASMs (16 Aug). All
   41 runs since 26 Aug are tagged, i.e. `run_cfg.sh`.

**One run hit it: the A/B baseline on 2026-08-28**, losing ~2 h of synthesis --
and even that was recovered by routing the existing netlist via `route_ab.sh`
rather than resynthesising.

### What WAS damaged: the documented reproduction path

`RESULTS.md` states "`build.sh` defaults to this configuration" and lists the
winning knobs. That path had never been executed end to end. Following the
documentation as written produced `command not found` after a two-hour wait.

The numbers stand -- they were all taken through `run_cfg.sh`. What did not
stand was the claim that build.sh reproduces them.

### Why it survived two days

The winning configuration was folded into `build.sh` as a convenience, and then
nobody used `build.sh`: every experiment went through `run_cfg.sh`, which skips
the ~2 h synthesis by reusing a netlist. A convenience path that nothing
exercises is not covered by the fact that the tool it wraps is heavily used.

### Lesson for this audit's own method

This is the **"appearing in build.sh is documentation, not evidence"** rule
(section 1) turning up in a new form. That rule was written about *knobs* named
in comments. The same trap applies to the **command that applies them**: a knob
folded into a script is not exercised until something runs that script.

`REUSE_JSON` (added the same day) makes build.sh cheap enough to run for real,
which is what would have caught this on day one.
