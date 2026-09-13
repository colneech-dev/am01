# The muxed miner: where it stands, and what happens next

Written 2026-09-13, after two independent reviews found real defects in both
the code and the reasoning. Supersedes the lever ordering in
`hdl/odocrypt/IMPLEMENTATION-REVIEW.md` §4f–§4h, which is **partly wrong** and
corrected below.

---

## 1. What is actually proven

| claim | evidence | status |
|---|---|---|
| `hashrate = BRAM × clk / 1680`, `/840` muxed | BRAM predicted 94.4% vs 94.38% measured; board measures 99.0 MH/s at 200 MHz vs 100.0 predicted | **sound** |
| `THROUGHPUT` cancels | mux3 vs mux4: `clk_h` 176.40 vs 176.09 across a 33% occupancy change | **sound**, well-controlled |
| Per-address-bit phase is equivalent | 439 defined cycles bit-identical, control fails all 439; independently re-derived by review | **sound** |
| `found_path` keeps every simultaneous find | 3,000-cycle randomised stress: strict accounting, zero unaccounted losses, zero duplicates | **sound** |
| Epoch 1789344000 core is correct | `tb_encrypt_oracle` vs an independent software OdoCrypt, bit-exact | **sound** |

## 2. What is NOT proven, and was stated as if it were

* **Every MH/s figure for the mux — 130.8, 152.8, 161.6, 158.3 — is an
  extrapolation from *inter-clock* slack on a build that FAILED timing.**
  §4g itself says the reported WNS is an inter-clock number, then §4f builds a
  "ceiling" table on the same construction. A ceiling that moves 175.53 →
  182.48 between builds is not a ceiling.
* **These are BRAM clocks 40–60% above the only frequency this board has been
  shown to hash correctly at.** `clk_gen_hash.v` records, in capitals, that a
  build closing at +0.335 ns produced **zero valid shares**, and that
  "225 MHz IS THE PROVEN CEILING until something measures otherwise. Do not
  re-derive a higher one from slack alone." That precedent was not cited.
* **No gate-level simulation exists anywhere in this repo.** All 20
  testbenches are RTL. So `DONT_TOUCH` being honoured, `ram_style="block"`
  giving the assumed BRAM latency, and the absence of retiming are unverified
  in the netlist that would be flashed — for a transform whose entire purpose
  is controlling what synthesis infers.
* Unsourced numbers now removed from the record: "a 55,538-load net" and "a
  quarter-million-load CE net" appear in no report. Actual fanouts are
  `clk_h` 128,688 and `clk_2x` 70,621.

## 3. The open question, and the experiment that settles it

**Two reviews reached opposite conclusions about the 7,807 hold violations.**

**(a) Artifact.** Every muxed build contains, unread until now:

```
WARNING: [Route 35-514] Design has a large number of hold violators.
Router is turning off hold fixing.
Resolution: ... set_param route.enableHoldExpnBailout 0
```

and the shipping 2-instance build — one design, no two-BUFG story — enters
routing with **worse** total hold violation and comes out clean:

```
shipping   WHS -0.246  THS -1512.039   ->  WHS +0.026  THS 0.000   (no bailout)
muxed      WHS -0.442  THS -16742.733  ->  bailout at Phase 5.2
```

§4f read that contrast as evidence for a clocking hypothesis. It is equally
evidence for a switchable heuristic.

**(b) Structural.** With `K` odd, the mux box's output demux writes one slot
on the `clk2x` edge coinciding with `clk_h` and the other mid-cycle — so half
of every box's output bits are a **same-edge `clk2x`→`clk_h` transfer**.
200 bits × 21 rounds × 4 miners ≈ 16.8k endpoints, the same order as observed.
RTL simulation only passes because `clk_h <= ~clk_h` in the non-blocking
region makes the new value win. If so, no constraint can fix it, and the
bailout is a *symptom* rather than the cause.

**The running experiment discriminates.** `vivado/route_with_hold_fixing.tcl`
sets `route.enableHoldExpnBailout 0` and routes from the **placed** checkpoint.
As of 13:47 the bailout warning is absent and `THS` has gone
**−17,218 → −8,614** — the router is doing something it has never done here.

* **hold reaches 0** → (a) is right, the rewrite is unnecessary, and there is a
  flashable muxed bitstream one MMCM rung away
* **hold stalls short** → (b) is right, and that is the evidence §4g needed and
  never had

## 4. Two earlier experiments that tested nothing

Recorded so they are not cited again as evidence:

* **`try_hold_fix.tcl`** — its own log says
  `-tns_cleanup is called on fully routed design. This will optimize the tns
  and all other options are ignored.` `-directive Explore` was discarded, the
  iterations report `WHS=N/A`, and the run reverted to its input routing.
  "−0.413 → −0.413" was one netlist measured twice.
* **`CLOCK_DELAY_GROUP`** — aimed at BUFG insertion skew, but the deficit
  decomposes as `0.197 (data) − 0.332 (skew) − 0.201 (uncertainty) − 0.061
  (Thold)`, and the 0.201 is MMCM CLKOUT-to-CLKOUT **phase error and jitter**,
  which no routing constraint touches. Intra-clock paths on a *single* net
  already show 0.263 of the 0.332. Roughly 0.05 ns was ever addressable.
  Worse, three variables changed in that build at once (per-bit phase,
  `CLOCK_DELAY_GROUP`, MMCM 24→19) and the result was attributed to one.

---

## 5. Plan

### Now — the discriminating run

Wait for `route_with_hold_fixing.tcl`. Nothing else should start on this
machine until it reports; it answers the question the last four builds did not.

### Branch A — hold reaches 0

1. Write a bitstream from the hold-fixed checkpoint.
2. Setup will still be short (`clkout1→clkout0` was −0.052 at MULT 19). Drop
   one MMCM rung: **MULT 18.5 → `clk_2x` 308.33, `clk_h` 154.2 MH/s**. Not
   158.3 — that figure came from the rung that fails.
3. Re-run `sim/run_encrypt_equiv.sh` (the RTL is unchanged, but the gate is
   cheap next to a wrong bitstream).
4. **Validate on hardware** with `tools/validate-bitstream.sh`: 100% pass rate,
   zero RECOVERED. Given §2, treat the first hardware run as the real
   experiment — every MH/s number so far is a static-timing extrapolation.
5. Abandon `claude/mux4-single-clock-ce`, keeping the branch for the record.

### Branch B — hold stalls short

The single-clock rewrite, per `docs/SINGLE-CLOCK-PLAN.md` on the branch, with
these corrections already applied or required:

* ✅ **`K` is one stage shallower under `SINGLE_CLOCK`** (`49127c8`). Measured:
  gated K=2 CE-high 0 mismatches, every other combination 49 of 49. Without
  this the branch would have been abandoned for a fixable reason.
* ✅ **`add_clock_enables()` asserts completeness** — it previously failed only
  on *zero* matches, so 427 of 428 would have passed silently.
* ⬜ **Step 4's fallback reasoning is wrong.** The wrapper boundary is not all
  quasi-static: `found_arr`/`nonce_flat_h` change every cycle and are exactly
  the path four bitstreams already got wrong. If the fallback is taken, the
  crossing that matters most is the one left in place.
* ⬜ **Step 4 double-count hazard.** If `found_path` ends up on `clk_2x`
  *without* an enable while the miners are gated, `found` becomes a two-cycle
  level and every find enters the FIFO **twice**. `found_path` must be gated in
  lockstep, or `THROUGHPUT` re-derived.
* ⬜ **Step 5 is not mechanical.** `add_clock_enables()` rewrites *always
  blocks*; `(* GATED_HALF_RATE *)` must go on *declarations*, which means
  resolving each gated block's LHS back to its `reg` statement. Write the
  count assertion **before** the attribute emission.
* ⬜ **Multicycle gives no hold relief, by construction.** `-setup 2 / -hold 1`
  keeps the hold check on the adjacent edge. Step 5 currently implies
  otherwise.
* ⬜ **Control sets.** 197,127 registers sit in 1,748 control sets at 89.5%
  LUT. Adding an enable to ~129,000 of them, replicated by `max_fanout`,
  multiplies control sets — registers with different (CLK, CE, SR) cannot
  share a slice. A packing risk, absent from the risk register.

### Independent of both branches

* ⬜ **GSR antiphase on the phase flops — fix before any silicon.** 7-series
  GSR deassertion is asynchronous and skewed across the die. Two `INIT=0`
  toggles released more than half a `clk_2x` period apart come up permanently
  in antiphase. For the *per-port* design that was a benign relabelling
  (`+pinv=1` measures it). For the **per-bit** design that shipped it is not:
  if `phase_a[3]` and `phase_a[4]` disagree, `a_addr` is a **mixture of slot-0
  and slot-1 address bits** — a wrong address into a shared table, on some
  power-ups and not others. Fix: a synchronous reset from a released-reset
  synchroniser, one net, not on any critical path.
* ⬜ **`tb_found_path_multi` T4's FIFO check is vacuous** — `fifo_count < 8`
  after `settle(40)` with an always-ready host is 0 by construction, so it
  cannot distinguish stash overflow from back-pressure, which is its stated
  job. Track a max watermark instead. Also `strobe()` races the DUT clock edge.
* ⬜ **`run_encrypt_equiv.sh` ignores its own third arm** — the
  `MUX_PHASE_FROM_PORT` revert path is built, run and printed, but the pass/fail
  decision reads only two logs. It could rot silently.
* ⬜ **One gate-level equivalence run** on the post-implementation netlist. §2.
* ⬜ **Correct §4f–§4h** to distinguish intra- from inter-clock slack, and to
  restate every MH/s figure as the extrapolation it is.

### The only hard deadline

**Epoch flash, Monday 2026-09-14 01:00 local (00:00 UTC).** Built, timing-met
(WNS +0.576, WHS +0.027), 8/8 sims, oracle-checked, waiting at
`vivado/artifacts/am01_200.00MHz_epoch1789344000_DO-NOT-FLASH-BEFORE-2026-09-14.bit`
(md5 `050efa48fcb5bcc35e3116ab2e05646b`). Needs the board; none of the above
does. Then replace `/boot/am01_200_rollback.bit`, still the stale 0x0203.

---

## 6. The lesson worth keeping

Three of the four "measurements" that drove §4f–§4h were not measuring what
they claimed: a hold-fix pass that did no hold fixing, a constraint aimed at
5% of the deficit, and a slack figure from the wrong path group. Each *looked*
like evidence, and each was reported here as decisive.

What caught them was not more building. It was reading the tool's own warnings
— `[Route 35-514]` sat in four build logs naming its own override — and having
someone independent attack the conclusions. **Both reviews should have been
run before the third build, not after the fourth.**
