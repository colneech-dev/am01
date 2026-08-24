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

9. **High-fanout driver replication — a TOOL fix, not a design change.**

   **Corrected 2026-08-24.** An earlier version of this item called for editing
   `encrypt.v` to replicate `crypt.progress[1]`. That was wrong, and measuring
   the netlist rather than reading the RTL is what showed it.

   In RTL that signal has **fanout 1**: `encrypt.v:15519` passes it as the
   `read` port of `encrypt_4encrypt_loop`, and inside that module `read` drives
   only `progress[0]` of a pure 172-stage shift register whose sole consumer is
   `assign write = progress[171]`. There is nothing in the source to replicate.

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
