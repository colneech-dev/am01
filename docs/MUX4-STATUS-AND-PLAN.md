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
does. Then replace `/boot/am01_200_rollback.bit`.

**DONE, and this line was wrong when written.** It called the rollback file
"still the stale 0x0203"; the board actually held 0x020B (md5
`050efa48…`, epoch 1789344000), staged 2026-09-13 — the right epoch all
along. The 0x0203 claim was carried over from an earlier state and repeated
without checking the board. As of 2026-09-15 19:27 the file is **0x020C**
(sha256 `1fcbd50c1cef2e1d7f6ec22f553d80126b0d2a1f88e5500a4184cf60025ddb5e`),
the same image now in SPI flash, upgraded so the recovery path carries the
clk_h meter rather than losing it. The 0x020B file is kept at
`/root/am01_200_rollback.prev-020B.bit`.

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

---

## 7. 2026-09-14/15 — the hardware attempts, and what they measured

**Nothing. Six flash writes, three of them mux4, and not one is evidence about
the 4-instance design.** Recorded here because the failure mode is subtle and
the temptation to read the logs at face value is strong.

### The three "mux4 fails when configured from flash" runs

15:07, 16:45 and 17:28 on 2026-09-15, all with the same fingerprint: VERSION
read times out, the daemon announces `FPGA v0.0`, epoch reads 0, every share is
withheld, and the die sits at 27 °C. That was read as a configuration-integrity
problem and chased through CONFIGRATE 33 and 6, `COMPRESS TRUE` and `FALSE`,
two separate builds, and a `--verify` readback. All five controls passed, which
should have been the clue.

The cause is in the host. `miner_io_pipe_init()` read VERSION **once**, with a
100 ms timeout, and on failure latched `g_version = 0` for the life of the
process. v0.0 is not a degraded mode:

| what v0.0 selects | consequence |
|---|---|
| `major < 2` | halt-on-find core, re-arm after every find |
| `ver < 0x00010008` | discard the first find of every job |
| seed 0 vs job epoch | "bitstream stale", refuse to submit |

So the daemon drove a protocol the loaded bitstream does not implement and
declined to submit the results. The cold die is the cores sitting halted, not a
dead fabric — and the XADC answering 27.3 °C in the same second the VERSION
read timed out proves the bus was alive throughout.

The daemon started **3 s** after each flash write. A PROGRAM_B reload leaves
the fabric in Hi-Z for 0.7–3.6 s depending on CONFIGRATE and bus width. Fixed:
the read now retries for ~10 s and then exits rather than inventing a version,
so `Restart=on-failure`/`RestartSec=30` retries into a configured fabric.

### The deeper problem: the experiment had no independent variable

Both wrappers reported **VERSION 0x020C**. The 2- and 4-instance designs differ
in instance count, clocking and S-box structure, and the one runtime way to
tell them apart said the same thing for both — so "the mux4 was running" was
always an inference from filenames and mtimes, never an observation.

Re-deriving the two best-instrumented windows from the pool's own share counts:

| window | rate | n | 1σ |
|---|---|---|---|
| mux4 over JTAG (SRAM), best two | 101.27, 100.58 MH/s | ≈1393, 1397 | ≈2.7% |
| shipping 2-instance | 98.69 – 102.27 MH/s | — | — |

**Statistically indistinguishable.** The 4-instance design has never been
measured faster than the design it replaces. It may well be; the record cannot
say. The 10h30m "at 100% valid" run often cited for it was a blend — the
process began on the stock image and was already at 2702 finds before the mux4
bitstream file existed.

mux4 now reports 0x020D and `sim/check_version_unique.sh` fails the build on a
collision.

### What this does and does not say about §5

The GSR antiphase hazard on the ~16,800 per-bit `phase` flops is **untouched by
all of this** — still unfixed, still the best mechanism-level explanation for a
config-mode-dependent fault, and now simply untested, since the runs that were
supposed to test it never reached the design. It stays ⬜.

Note that `clk_gen_hash.v` sets `STARTUP_WAIT("FALSE")` and nothing sets
`BITSTREAM.STARTUP.LCK_CYCLE`, so GSR releases hundreds of microseconds before
the MMCM locks, and the phase flops free-run on `clk_2x` throughout lock
acquisition. `STARTUP_WAIT TRUE` + `LCK_CYCLE 6` closes that window and can be
tried from the routed checkpoint without a rebuild — but the synchronous reset
§5 specifies is the actual fix, and it costs one net off any critical path.

### The discriminating test, still unrun

Flash mux4, then with the daemon **stopped**:

```sh
am01-fpga-reload            # reloads from flash; does NOT restart the miner
sleep 20
am01_reg 0x00               # expect 0x020D, not 0x020C and not 0x0000
am01_reg 0x1D               # clk_h ticks — non-zero, and differencable
openFPGALoader --read-register STAT
```

`STAT` with `EOS=1 DONE=1 CRC_ERROR=0 ID_ERROR=0` kills the entire
configuration-integrity family in one command. It costs ~10 minutes of mining
and is the only thing that separates "the design is wrong" from "the host was
mis-moded", which is why it must run before any further build.

### The lesson, again

§6 says both reviews should have been run before the third build. They were run
after the sixth flash — and the first thing they found was that the instrument
could not distinguish the two things being compared. **Check that an experiment
can produce a different answer before running it a third time.**

---

## 8. 2026-09-15, evening — the mux4 design has never run

Measured on the board, not inferred. Register 0x1D (the clk_h meter) reached
hardware for the first time this evening and settled the question in one
afternoon.

### First, the meter is trustworthy

Conservative 2-instance image, configured **from flash**:

```
STAT: EOS 0x1  Done 0x1  Release Done 0x1  No CRC error  No ID error
VERSION 0x020c
CLK clk_h = 200.01 MHz        WINDOW 60s hashrate = 100.33 MH/s
```

`hashrate = miners × clk_h / T` = 2 × 200.01 / 4 = **100.01 predicted vs 100.33
measured, 0.3%**. The governing law is now confirmed on hardware rather than
assumed, and the meter is calibrated against a known-good design.

It also proves the flash configuration path is sound on this board: `EOS=1`,
`Done=1`, no CRC or ID error. Every configuration-integrity hypothesis — droop,
CRC, CONFIGRATE, bus width, compression — is dead for this board and procedure.

### mux4 from flash: DONE never asserts

```
STAT: EOS 0x0  Done 0x0  Release Done 0x0  No CRC error  No ID error
```

**Four reloads, four identical results.** The bitstream is intact (no CRC, no ID
error) but the FPGA never completes its startup sequence, so the I/Os stay
Hi-Z — which is why VERSION reads 0xffff and every register read times out.
"No CRC error" here means configuration never *reached* the final CRC, not that
it passed one.

The determinism matters: **this is not the §5 GSR antiphase hazard.** That
predicts a per-power-up coin flip. Four out of four identical says a startup
sequence gated on a condition that never becomes true.

### mux4 in SRAM: the FPGA falls back to the flash image

All three mux4 artifacts (`_133`, `_020C`, `_nocomp`) loaded with
`openFPGALoader -m`, each reporting success and `Done=1`:

| artifact | VERSION | clk_h |
|---|---|---|
| am01_mux4_133.bit | 0x020c | 199.91 MHz |
| am01_mux4_020C.bit | 0x020c | 199.97 MHz |
| am01_mux4_nocomp.bit | 0x020c | 199.96 MHz |

`hdl/mux4/am01_qmtech_top_mux4.v:92` hard-codes `CLKFBOUT_MULT(16)` /
`CLKOUT_DIVIDE_2X(3)` = **clk_h 133.33 MHz**. Every one of them measured 200,
which is the *conservative* design's clock. `am01_mux4_133.bit` predates the
0x020C bump and should report 0x020B; it reported 0x020c — the value sitting in
flash at that moment.

**The negative control that makes this conclusive.** Loading a different
known-good 2-instance build (`am01_rollover_1789344000.bit`, VERSION 0x020B)
the same way:

```
VERSION now: 0x020b        (flash holds 0x020C)
```

So `-m` genuinely replaces the fabric. It follows that when a mux4 bitstream is
loaded, configuration fails and **the FPGA falls back to the image in SPI
flash**, ending at `Done=1` running the conservative design. From flash there is
no good image to fall back to, so DONE simply stays low forever.

### What this means

**mux4 has never run on this board.** Not at 106 MH/s, not at 100, not at all.
Every "mux4" measurement in this repo's history — the 10h30m at 100% valid, the
101.27 and 100.58 MH/s windows, the "all four instances alive" nonce-quadrant
test — was the conservative 2-instance design answering through a silent
configuration fallback.

That is why mux4 always measured *identical* to the shipping image rather than
merely disappointing. §7 showed the record could not distinguish the two; this
shows there was never anything to distinguish.

### Next, in order

1. **Find why configuration does not complete.** The bitstream is intact and the
   design met timing, so look at the startup sequence, not the netlist: compare
   `BITSTREAM.STARTUP.*` defaults actually baked into each .bit, and check
   whether the mux4 build's MMCM is gating DONE (`STARTUP_WAIT`, `LCK_CYCLE`).
   `clk_gen_hash.v` sets `STARTUP_WAIT("FALSE")`, which should *not* gate DONE —
   verify that is what the mux4 bitstream actually contains.
2. **Nothing about mux4's performance can be claimed until it configures.** Do
   not rebuild for speed, do not retune the MMCM, and do not quote a mux4
   hashrate.
3. The 0x020D VERSION from commit 8cecc70 is not in any built artifact yet. The
   first mux4 build that configures must be checked with `am01_reg 0x00`
   returning **0x020d** and `0x1D` measuring **~133 MHz** before any number it
   produces is recorded.

### The lesson, third time

§6 said read the tool's own warnings. §7 said check the instrument can tell the
two cases apart. This one is sharper: **`openFPGALoader` reported success and
`Done=1` for a bitstream that had not been loaded.** The tool was not lying —
the FPGA really was configured and really was done, just with a different
design. A success message answers "did the operation complete", never "is the
thing I wanted now true". Only the clk_h meter could answer the second, and it
took a week to build.
