# Router criticality testing: T6–T8

Measurements for three RWRoute recommendations (confirmed to exist in this tree, default-off, never run).

---

## Quick start

```bash
# After the SRL-free netlist is placed, or using an existing placed.json:
./test_criticality_knobs.sh out_nm1_srl0/placed.json am01_qmtech_top test_results/
```

Each test runs nextpnr's route on the **same placement**, with one knob varied. Results go to `test_results/test_t{6,7,8}_*.log`.

---

## The tests

### T6: Is criticality meaningful?

```
NEXTPNR_LOG_CRIT_GAP=1
```

**Gate test.** Reports `routed_delay / predicted_delay` per iteration.

router2 does not bind wires until `overused == 0`, so during negotiation criticality
comes from `predictDelay()` — a Manhattan estimate of the **placement** — not from actual
routed delay. The timing feedback loop is open.

- **ratio ≈ 1.0** → criticality is sound, and T7/T8 weight something real
- **ratio 3–4×** → criticality is fiction, T7/T8 weight noise; close the loop first

**Decision rule:** If ratio >> 1, stop here and do something about the feedback loop (e.g.
seed router's history costs from a first full route, re-run). If ratio ≈ 1, proceed to T7.

---

### T7: Criticality-weighted path cost

```
NEXTPNR_CRIT_WEIGHT=0.4       (then 0.6)
```

**What it does:** Blends delay and congestion by arc criticality (exact PathFinder form):

```
cost = crit * delay + (1 - crit) * congestion
```

- `crit=1.0` (critical arc) → cost ≈ delay, congestion ignored
- `crit=0.0` (slack arc) → cost ≈ congestion, routes for shortest path in fabric

**Why it matters:** openXC7's baseline router has **no criticality weighting on the arc's own cost**. A critical arc paying the same congestion multiplier as a slack arc will happily take a long detour to avoid mild congestion. RWRoute's form separates concerns: critical paths chase delay, slack nets absorb congestion.

**Caveat:** Do NOT use 1.0. `arc_crit` clamps to exactly 1.0, so `CRIT_WEIGHT=1.0` makes the most critical arcs completely congestion-blind and prevents convergence. Typical values are 0.4–0.6.

**Measurement gate:** Watch `overused` as closely as `clk_h`. A 1.78× Fmax improvement is worthless if convergence now stalls at 120+ unrouted arcs (see baseline logs).

---

### T8: Criticality-aware sharing

```
NEXTPNR_SHARE_EXP=1    (then 2, then 3)
```

**What it does:** The existing router has `/ (1 + source_uses)` — a divisor that makes
a wire carrying this net cheaper, rewarding later arcs of a multi-sink net to branch off
an existing trunk. This is applied **identically regardless of criticality**.

RWRoute applies it selectively:

```
share = (1 + source_uses) ^ (1 - min(1, e * crit))
```

- `crit=0.0` → `share = 1 + source_uses` (no change)
- `crit=1.0, e≥1` → `share = 1` (no discount at all)
- `e=0` → disabled (bit-identical to before)

**Why it matters:** This design has ~7 sinks per net. Every later arc — including critical ones — is paid to detour into the shared trunk. That is a plausible source of the measured 13 ns net delays against Vivado's 3.8 ns on the same path type.

**Parameters:**

- `e=1`: sharp cliff; critical arcs get almost no sharing discount
- `e=2`: RWRoute's default; smooth curve
- `e=3`: gentler curve; more sharing even for critical arcs

**Measurement:** T7 and T8 interact. Measure each alone first, then combine the best settings.

---

## Workflow

1. **T6 first.** Gate test. If criticality is fiction, everything below becomes speculative.

2. **T7 vs baseline.** Pick 0.4 or 0.6 based on convergence and Fmax. Watch overused.

3. **T8 vs baseline.** Try 1, 2, 3. Pick the best.

4. **Combine T7_best + T8_best**, measuring together to catch interactions.

5. **Against the 89.30 MHz baseline** (seed 7, striped, converged at iter 45):
   - Measure `clk_h` (timing)
   - Measure `overused` at convergence and iteration count
   - Measure routing runtime

Do **not** gate on post-place timing estimate. That improved for floorplanned runs while routing got worse. Measure routed timing only.

---

## Interpretation

**If T7 + T8 combined yield ~120+ MHz:** The router's cost model is the 1.78× gap. Stop here, submit upstream, call the design done.

**If T7 + T8 combined yield ~95–110 MHz:** Modest gain, router is one part of the gap, placement work (congestion-aware, BRAM spreading, etc.) becomes worthwhile.

**If T7 + T8 combined yield ~89 MHz (no change):** Criticality weighting is not the lever. Back-burner these, focus on placement or verify whether the delay model itself is the issue (see CONGESTION-RESEARCH-PLAN.md section 5).

---

## Known unknowns

- **Interaction with floorplanning:** These tests use `placed.json` as-is. If the SRL-free netlist was placed unconstrained, we're testing criticality weighting on a placement that may be suboptimal for routability. Ideally measure against both a floorplanned and an unconstrained placement.

- **Convergence rate vs quality:** Criticality weighting makes early iterations route faster for critical paths, but may sacrifice non-critical-path routability, leading to more total iterations. Watch iteration count as much as final Fmax.

- **Interaction with other router knobs:** These tests don't touch `estimateWeight`, `bbMargin`, or `curr_cong_weight`. Independent experiments (Step 0 in CONGESTION-RESEARCH-PLAN.md) should precede these.

---

## References

- CONGESTION-RESEARCH-PLAN.md § 3 Step 3, RWRoute agent findings
- RWRoute.java lines 1703–1708, 2072–2073, 2078–2083, 2166–2170, 2184–2204 (cost function)
- router2.cc lines 486–524, 617–622 (openXC7 implementation)
- TESTS-TO-RUN.md T6, T7, T8
