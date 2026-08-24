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
