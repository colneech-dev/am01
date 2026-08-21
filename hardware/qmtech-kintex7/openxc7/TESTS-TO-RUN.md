# Tests to run

Everything built, changed, or claimed during the 2026-08-20/21 session that has
**not** been verified by measurement. Ordered by value-per-effort, not by topic.

Companion to `SESSION-2026-08-21.md` (what was done and what it proved) and
`QUARANTINED-BITSTREAMS.md`.

A note on why this list is long: the two changes that actually moved the number
were found by instrumenting and reading counters. Nearly every hypothesis reached
by reasoning about the source was later refuted by measurement. Treat everything
below as unproven until it has a number attached.

---

## P0 — regressions from this session's own changes

These verify that fixes committed on 2026-08-21 did not break the working flow.
Nothing else should be run until these pass.

### T1. build.sh still builds
```
FREQ=133.33 ./build.sh am01_qmtech_top out_test <srcs...>
```
`build.sh` gained a required `FREQ`, three hard gates, and stale-artifact
removal. **Expect it to FAIL on the unrouted-arc gate** with the current flow —
that is the gate working, not a regression. Confirm the failure message names the
arc count, then re-run with `OPENXC7_ALLOW_UNROUTED=1` and confirm it proceeds.

- [ ] fails cleanly with FREQ unset
- [ ] fails on unrouted arcs, message is accurate
- [ ] `OPENXC7_ALLOW_UNROUTED=1` overrides
- [ ] no stale `.frames`/`.bit` left after a mid-flow failure

### T2. Reset-race fix does not change functional behaviour
`req_toggle_bus` is now reset-less. It should be invisible in normal operation
and only matter across a reset.

- [ ] simulate: normal request/ack handshake still works
- [ ] simulate: assert `bus_rst_n` mid-`S_WRITE` while `req_toggle_bus == 1`,
      assert `get_block_pulse_h` count is **unchanged** (this is the actual bug)
- [ ] confirm synthesis does not now infer a latch or warn on the un-reset flop

### T3. XDC PULLUP change reaches the bitstream
```
grep -c 'PULLTYPE.PULLUP' out/*.fasm     # expect >= 2
```
- [ ] `gpio_wr_n` and `gpio_rd_n` IOBs show PULLUP, not PULLTYPE.NONE
- [ ] no other IOB changed

### T4. nextpnr rebuild is behaviour-neutral with all knobs off
Four commits touched `router2.cc` and `arch.cc`. With every new env var unset,
the router should be **bit-identical** to before except for the BRAM timing.

- [ ] iteration 1 reports `wires=1399222 overused=135026` (the long-standing
      reference for seed 7, unfloorplanned)
- [ ] `HeAP congestion knobs:` line reads `beta=0.400 ... alpha=0.080 crit_exp=7.0`
- [ ] final unrouted count matches the pre-change run for the same input

---

## P1 — the question that decides where effort goes next

### T5. Vivado placement + nextpnr routing  ← **highest value single test**
Separates "the router's cost model is wrong" from "the placement is
unroutable-and-slow". That ambiguity has driven most of this work.

```
yosys -> JSON -> nextpnr --pack-only
      -> xilinx/java/json2dcp.java -> DCP
      -> Vivado place_design -> export placement
      -> BEL attrs -> nextpnr route
```

- [ ] good timing (approaching Vivado's 162 MHz) -> the router is fine, the
      placer is the whole problem; stop tuning router cost functions
- [ ] still ~65 MHz -> the router's cost model matters; T6-T10 become worthwhile

Not a shippable open flow (needs Vivado). Purely diagnostic.

### T6. Is criticality meaningful at all?
```
NEXTPNR_LOG_CRIT_GAP=1
```
Reports `routed/predicted` delay ratio per iteration. During negotiation
criticality comes from `predictDelay` — a Manhattan estimate of the **placement**
— because router2 never binds wires until `overused == 0`. The timing feedback
loop is open.

- [ ] ratio near 1.0 -> the estimate is sound, T7/T8 are weighting something real
- [ ] ratio 3-4x -> criticality is fiction, and **T7/T8 are weighting noise**;
      closing the loop matters far more than tuning either

**Run this before T7 and T8.** It can invalidate both.

Caveat: delay is captured at the forward-A* success site only. Arcs completed by
the backward BFS report -1 and are excluded.

---

## P2 — router knobs: built, never run

All default-off. All should be measured against the same baseline, one at a time.
Watch `overused` as closely as `clk_h` — letting critical arcs ignore congestion
is a classic way to prevent convergence.

### T7. Criticality-weighted cost
```
NEXTPNR_CRIT_WEIGHT=0.4      then 0.6
```
- [ ] `clk_h` improves vs baseline
- [ ] `overused` still reaches 0
- [ ] does NOT stall the way the 2M-budget run did (~120 overused, oscillating)

Do **not** use 1.0: `arc_crit` is clamped to exactly 1.0, so w=1.0 makes the most
critical arcs completely congestion-blind.

### T8. RWRoute-style criticality-aware sharing
```
NEXTPNR_SHARE_EXP=2          RWRoute's default; try 1 and 3
```
Targets the `/(1 + source_uses)` divisor, which pays every later arc of a
multi-sink net to detour into the existing branch regardless of criticality.
This design has ~7 sinks per net.

- [ ] `clk_h` improves
- [ ] routing still converges
- [ ] combined with T7 (only after each is characterised alone)

### T9. Isotropic heuristic
```
NEXTPNR_ISO_HEURISTIC=1
```
- [ ] routed critical-path **net delay** improves
- [ ] router runtime does not blow up (this is the trade `estimate_weight=1.75`
      was buying)
- [ ] optionally combine with `--router2/estimateWeight 1.0`, but **not** in the
      same run as the isotropy change — that confounds both

### T10. A* cost relaxation
```
NEXTPNR_ASTAR_RELAX=1 NEXTPNR_ASTAR_RELAX_EPS=0.05     then EPS=0
```
Known cost: ~22 min/iteration vs ~5 at EPS=0. The thresholded version recovered
about half the quality gain. **Worth retrying only after T9**, since a
better-calibrated heuristic should cut re-expansions sharply.

- [ ] per-iteration time acceptable
- [ ] congestion advantage persists to convergence (it was −5.7% at iteration 3)

---

## P3 — correctness verification that has never been done

### T11. X-propagation check on the physical netlist  ← **catches the silent-wrong-results class**
The repo's own example (`xilinx/examples/counter25/build.sh` steps 3-4) routes,
converts to DCP, and runs `VerilogPhys` + iverilog asserting **X-cycles must be
zero**.

- [ ] run it against a current build
- [ ] would catch both the unrouted-LUT-cofactor bug and any floating BRAM input
      *before* programming a board

This is the single most valuable untested item after T5.

### T12. Post-synthesis whole-design simulation
Needs no hardware. `write_verilog` the `synth_xilinx` output and run it against
`sim/tb_encrypt_equiv.v`.

- [ ] hashes match the RTL reference

Note: all 420 large S-box ROMs were already verified bit-exact **at FASM level**,
and one small S-box was proven equivalent by SAT miter with a working negative
control. What is missing is the whole design end-to-end.

### T13. Const-net holdouts
```
NEXTPNR_LOG_CONST_HOLDOUTS=1
```
`routeVcc()` is best-effort and runs **after** the router; its log line says
"left to main router", which is wrong — nothing routes them afterwards. VCC
holdouts have no dump file and no recovery path (only GND does).

- [ ] holdout count is 0 for **both** rails
- [ ] if not, check whether any holdout sink is a `RAMB18*` control pin
      (`RSTRAM*`/`ENARDEN` are invertible pins, so a logical 0 tie becomes
      VCC + `IS_*_INVERTED`; a floating one asserts the RAM reset) or a SLICE
      `A1..A6` (feeds straight into the LUT-cofactor bug)

### T14. Frames/bitstream integrity
Everything so far has verified the **FASM**. Nobody has checked frames→bit.

- [ ] append a garbage feature line to a known-good FASM; does `fasm2frames`
      error, or silently drop it?
- [ ] frames-level diff against a Vivado golden, using the existing
      `hardware/qmtech-kintex7/vivado/` build

---

## P4 — open design questions

### T15. Is the dfflegalize workaround now obsolete?
`synth_fdre_only.ys:40` carries `-minsrst 999999999 -mince 999999999`, forcing
every reset and clock-enable into LUT logic (confirmed: `SRUSEDMUX` and
`CEUSEDMUX` are both 0 across 27,607 FDREs). The control-set bug it worked around
was fixed by `bf78fccf` (2026-08-03).

- [ ] rebuild without the overrides
- [ ] does "control-set contention in the placement" return?
- [ ] if not, how many LUTs does it save?

**Deliberately not tested during the session.**

### T16. NUM_MINERS=2
Vivado does it (840 BRAMs, 162 MHz). openXC7 has only ever built `nm1`.

- [ ] 840/890 BRAM = 94% utilisation — striping has almost no room to distribute
      egress at that density
- [ ] `floorplan_stripe.py` already groups by (miner, round); harvest 840 sites
      via a fresh `--no-route --write`
- [ ] does it route at all?

### T17. Seed robustness of the striped floorplan at the new settings
4/4 seeds routed to 0 unrouted, but `clk_h` varied 93.68 - 135.32 MHz across
them — and those figures predate BRAM timing, so **all four need re-measuring**.

- [ ] re-run the 4 seeds with BRAM timing active
- [ ] is timing still that seed-sensitive once memories are in the graph?

---

## P5 — upstream

### T18. File the two issue drafts
Needs `gh auth login` (installed on both Windows and WSL, unauthenticated).

- [ ] `upstream-issue-1-placer-flags.md`
- [ ] `upstream-issue-2-router2-relaxation.md`

### T19. Consider a third issue
Neither the missing hard-block timing (`RAMB` absent from `getPortTimingClass`)
nor the open timing feedback loop (`predictDelay` fallback during negotiation)
appears in upstream issue #470, the Timing Analysis Improvements meta-issue.
Both look unreported and both are more consequential than the two already
drafted.

- [ ] verify against current upstream before filing — our tree has diverged

---

## Deliberately NOT to be re-tested

Refuted by measurement during the session. Re-running these is waste; the full
list with evidence is in `SESSION-2026-08-21.md`.

Wire reservations · rigid route trees · A* heuristic degeneration · serial thread
bin · failed-net re-route pass · frozen-tile bypass · bigger search budget ·
cell-count occupancy penalty · columns-per-round tuning · seed hunting ·
`--placer-heap-alpha` · "HeAP discards its best placement" · "prjxray pip delays
are a stub" · RWRoute/DREAMPlaceFPGA adoption.
