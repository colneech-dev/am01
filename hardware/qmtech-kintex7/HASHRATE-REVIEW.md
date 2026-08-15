# Hash-rate review — OdoCrypt on XC7K325T

Review of the hash core as built by this directory: `hdl/odocrypt/{encrypt,keccak800,miner,
atomminer_misc}.v` plus `hdl/{clk_gen_hash,odocrypt_gpio_wrapper,am01_qmtech_top}.v`, targeting
**XC7K325T-1FFG676C** (890 RAMB18, 203,800 LUT, 840 DSP).

Scope note: the stock AM01 files (`atomminer_odocrypt.v`, `usb3_interface.v`, `usb3_sm_v3.v` and
the Artix IP) are deliberately excluded from `vivado/build.tcl`, so they are out of scope here. A
correctness review of those, including six bugs in the FX3 interface, is in git history at
`635fab3` under `exmaples/odocrypt/fpga/HASHRATE-REVIEW.md`.

What is verified how. The pipeline structure and latency claims were checked by RTL simulation
(`exmaples/odocrypt/fpga/src/sim/miner_latency_tb.v`, Icarus) and by reading the generated RTL.
Two numbers below were **re-measured independently for this review** with yosys 0.33
(`synth_xilinx -family xc7`), noted inline where they appear. The Fmax figures are this branch's
own nextpnr measurements and were *not* reproduced — there is no nextpnr in the review
environment, and no Vivado (nor any free tier for this part). New claims are marked as analysis.

Everything here uses the open-source toolchain: yosys + nextpnr-xilinx per `openxc7/`.

---

## 1. The entire problem, in four numbers

```
measured, stock      2 instances @ 84.90 MHz, T=4   ->  42.5 MH/s
measured, mux2       4 instances @ 51.86 MHz, T=4   ->  51.9 MH/s   (1.22x)
mux2 if clk_2x closed at 2 x 84.90 = 170 MHz        ->  84.9 MH/s   (2.00x)
```

`sbox_large_mux2` already halves block RAM per instance and is proven bit-exact. It already fits
4 instances. The only thing standing between 51.9 MH/s and 84.9 MH/s is that **`clk_2x` measures
103.72 MHz where it needs ~170**.

Everything else on this chip is a rounding error. That is the finding this review is built around,
and §3 is the part worth reading.

---

## 2. THROUGHPUT is a free variable on this chip — and that has not been spent

`README.md` concludes that "tuning THROUGHPUT alone buys nothing". **That conclusion is correct**,
and the corrected model below agrees with it more strongly than the one in that file does. But it
is stated as a dead end, when it is actually a degree of freedom.

### 2.1 Correcting the model first

`README.md` derives block RAM from Keccak's unrolling: "`keccak800.v` sets `UNROLLING =
(12-1)/THROUGHPUT + 1`, and BRAM scales with unrolling — measured 420 RAMB18 at UNROLLING=3, i.e.
140 RAMB18 per unrolled round."

**`keccak800.v` contains no memories at all.** It is pure XOR/AND logic — theta, rho, pi, chi,
iota. Every one of the 420 RAMB18 is in `encrypt.v`: 20 `sbox_large` instances per round
(`encrypt_4apply_sboxes`), across **21** unrolled *encrypt* rounds, where encrypt's unrolling is
`(84-1)/T + 1 = 21` at T=4. So the correct constant is **20 RAMB18 per unrolled encrypt round**,
not 140 per unrolled Keccak round.

*Measured for this review:* a two-round wrapper (`encrypt_4full_round` ×2) through
`synth_xilinx -family xc7 -flatten` gives **40 RAMB18 — exactly 20 per round**, scaling to
20 × 21 = 420 at T=4, which is the figure in `utilization.txt` and this branch's own count. The
total was never in dispute; what it scales with was.

The published table is still numerically right at T = 4, 6, 12 — but only by coincidence, because
encrypt's unrolling happens to be exactly 7 × Keccak's at those three points (21=7×3, 14=7×2,
7=7×1). It breaks elsewhere. At **T=7** the old model gives Keccak `UNROLLING=2` → 280 RAMB18;
the true figure is encrypt `UNROLLING=12` → **240 RAMB18**.

### 2.2 The corrected table

With `U = (84-1)/T + 1`, block RAM per instance `= k·U` (k=20 stock, k=10 with mux2),
`C = floor(890 / k·U)` instances, and rate `= C/T` hashes per `clk_h` cycle:

| T | U | stock BRAM/inst | C | rate | mux2 BRAM/inst | C | rate | LUT |
|---|---|---|---|---|---|---|---|---|
| 4 | 21 | 420 | 2 | 0.500 | 210 | 4 | 1.000 | 82% |
| 6 | 14 | 280 | 3 | 0.500 | 140 | 6 | 1.000 | 82% |
| **7** | **12** | **240** | **3** | **0.429** | **120** | **7** | **1.000** | **82%** |
| 8 | 11 | 220 | 4 | 0.500 | 110 | 8 | 1.000 | 86% |
| 12 | 7 | 140 | 6 | 0.500 | 70 | 12 | 1.000 | 82% |
| 21 | 4 | 80 | 11 | 0.524 | 40 | 22 | 1.048 | 86% |

Rate is **flat in T** — 0.50 × f stock, 1.00 × f with mux2, varying by under 5% across the whole
range. `README.md` is right: the block RAM budget fixes the ceiling and T cannot move it.

**But that is exactly what makes T free.** It costs nothing to change, so it can be spent on
something other than rate.

### 2.3 What it should be spent on

`tools/mux2_pipelined_transform.py` records that a +1-cycle-per-round variant is unschedulable:

> `+1 cycle/round -> loop 64,  gcd(4,64)=4   BROKEN`

That is true **at T=4, and only at T=4.** The loop depth with one extra stage per round is
`3U + 1`, and the requirement is `gcd(T, 3U+1) = 1`:

| T | U | loop `3U+1` | gcd | schedulable? |
|---|---|---|---|---|
| 4 | 21 | 64 | 4 | no — what was tested |
| 5 | 17 | 52 | 1 | **yes** |
| **7** | **12** | **37** | **1** | **yes** |
| 9 | 10 | 31 | 1 | yes |
| 11 | 8 | 25 | 1 | yes |
| 13 | 7 | 22 | 1 | yes |

T=4 is one of the few values in the range where it fails. The transform was written against a
THROUGHPUT that was treated as fixed, the gcd came out wrong, and the +1 variant was recorded as
structurally impossible — when it is available at almost every other T, at **zero rate cost**
(§2.2: T=7 with mux2 gives 7 instances × 1/7 = 1.000 × f, identical to T=4's 4 × 1/4).

This is the single most actionable thing in this review: **the +1-stage mux2 variant was ruled out
on a constraint that dissolves if THROUGHPUT moves, and THROUGHPUT is free.**

---

## 3. Why `clk_2x` does not close — and why the diagnosis matters

`sbox_large_mux2.v` explains the shortfall as:

> The S-box address is not register-driven. It arrives through combinational logic from the
> previous pipeline stage and settles about 9.6 ns into an 11.78 ns `clk_h` period.

**The first sentence is wrong, and it changes what to do about it.** `encrypt_4apply_pbox0` is 640
plain `assign out[j] = in[i];` statements — verified, zero arithmetic or logic operators anywhere
in the module. The S-box address is a pure *permutation of `state[i]`*, a flip-flop output, at
**zero logic levels**.

So the 9.6 ns is not combinational depth. It is **routing** — a 640-bit die-crossing shuffle from
one round's state registers to that round's 20 block RAMs.

### 3.1 First open-source measurements of it

Built here from scratch to check this: yosys 0.33, nextpnr-xilinx at main `8b836d6`, and a
Kintex-7 chipdb generated for `xc7k325tffg676-1` (462 MB, matching `openxc7/README.md`). The test
design is `N` chained `encrypt_4full_round` stages with state registers between them — the encrypt
loop's exact structure, cut down to 3 I/O pins.

| design | RAMB18 | post-place | post-route |
|---|---|---|---|
| 2 rounds | 40 | 177.78 MHz | 165.98 MHz |
| 21 rounds (= one instance's S-box load) | 420 | **178.25 MHz** | *(routing, see below)* |
| this branch's full 2-instance build | 840 | 146.20 MHz | — |

**Two caveats that matter more than the numbers.** My nextpnr is stock — it does *not* carry
`openxc7/patches/0001-xc7-block-ram-timing.patch`, so block-RAM paths are untimed. These figures
are therefore the same flavour as this branch's 146.20 MHz, **not** its 84.90 MHz. And the probe
has no Keccak, no miner wrapper and one instance rather than two.

Like-for-like, then: 178 MHz at 420 block RAMs against 146 MHz at 840 with the full design around
it. **Going from 40 to 420 block RAMs cost nothing at all** (177.78 → 178.25 post-place). That is
weaker support for congestion than §3's argument assumes — a single instance's S-box load does not
degrade placement on this chip, and the drop to 146 MHz comes from whatever the second instance
and the wrapper add. The 42% that block-RAM timing then removes (146 → 85) is a *timing-model*
effect, not a placement one.

### 3.2 Placement spread at full S-box density — measured

`openxc7/report_sbox_paths.py` on the placed 21-round probe (420 RAMB18, all 21 rounds):

```
  round  BRAM bbox [RAMB18 grid]   addr driver bbox [SLICE grid]    drv spread
  0      3-3,  98-139 (20)         0-59, 171-345 (640)                     233
  7      5-6,   0-24  (20)         0-75,  76-345 (640)                     344
  14     0-1,  95-139 (20)         0-13, 171-345 (640)                     187
  20     0-0,   0-53  (20)         0-15,  98-345 (640)                     262
        (21 rounds total; spread ranges 187-344, worst 344)
```

The pattern is consistent across all 21 rounds and it is lopsided: **each round's 20 block RAMs
are placed tightly** — one or two BRAM columns, 25–45 rows — **while the 640 flip-flops feeding
their address pins are spread across essentially the whole fabric**, up to 75 slice columns and
270 slice rows. The placer clusters the memories and scatters their address sources.

That is the shape §3 predicts, now at one full instance's S-box load rather than a toy design.

**And yet stock Fmax does not move: 178.25 MHz, the same as the 2-round probe.** That is because
nextpnr is not timing the path at all. `build-nextpnr-bramtiming.sh` states it plainly — with
block RAM absent from `getPortTimingClass()`, "a block RAM output is not a timing start point,
**its address inputs are not endpoints**, and any critical path through a memory is invisible".
The stock 178 MHz is blind to exactly the net bundle measured above.

### 3.3 Confirmed: the address path is real, and it scales with S-box count

Rebuilt nextpnr with `patches/0001-xc7-block-ram-timing.patch` (which applies cleanly to main
`8b836d6`, not only to the 0.9.2 its script pins) and re-placed both probes unchanged:

| design | RAMB18 | stock, BRAM untimed | **BRAM timed** | path added |
|---|---|---|---|---|
| 2 rounds | 40 | 177.78 MHz (5.625 ns) | **136.91 MHz** (7.304 ns) | +1.68 ns |
| 21 rounds | 420 | 178.25 MHz (5.610 ns) | **78.44 MHz** (12.749 ns) | **+7.14 ns** |

This is the measurement §3 needed, and it confirms the hypothesis.

The fixed block-RAM arc — 0.566 ns address setup plus 2.454 ns clock-to-out — is *identical* in
both designs. If that were the whole story both would lose the same ~1.7 ns. They do not: the
420-BRAM design loses **5.46 ns more** than the 40-BRAM one. That excess is not a property of the
memory; it is the address path getting longer as the S-box count grows, exactly as §3 argues, and
it is invisible to any tool that does not time BRAM arcs.

It also reconciles with this branch's own numbers. One instance's S-box load timed at 78.44 MHz
sits just below the 84.90 MHz measured for the full two-instance build, and the ~7 ns of address
path here is the same order as the "~9.6 ns into an 11.78 ns period" quoted in
`hdl/sbox_large_mux2.v`.

**Verdict: §3 holds.** The hash core is placement-bound on a zero-logic net bundle, the stock flow
cannot see it, and floorplanning is therefore the lever — step 2 of §4 is now the highest-value
thing to try, and `report_sbox_paths.py` gives the before/after metric for it.

### 3.4 Practical notes for reproducing the above

- `cmake -DBUILD_PYTHON=OFF` — nextpnr's Python bindings need dev headers, and nothing here uses
  them (`report_sbox_paths.py` parses JSON offline, by design).
- `bbasm` builds to `build/bbasm`, not the `build/bba/bbasm` that `build-chipdb.sh` expects.
- **Routing the 21-round probe was killed twice for memory** on a 16 GB machine. Two fixes, both
  effective: add swap (`fallocate -l 12G /swapfile && mkswap && swapon`), and use **`--no-route`**
  — the diagnostic reads `NEXTPNR_BEL`, which is assigned at placement, so routing is not needed
  for it at all. Placement-only completes comfortably and writes the JSON.
- `build-chipdb.sh` pins `NEXTPNR_TAG=0.9.2` while `README.md` says 0.9.2 cannot route and to use
  HEAD. Use one revision for both the binary and the chipdb; mixing them risks a format mismatch.

Three things follow from the structure regardless, none of which are in the current docs:

**The stock design is already routing-bound, not logic-bound.** 9.6 ns of a 11.78 ns period —
**82% of the clock** — is one zero-logic net bundle. The 84.90 MHz figure is a placement result,
not a fabric limit.

**There is no floorplanning anywhere in this build.** The only placement constraint in the entire
repository is one `set_property LOC` on the AM01's USB system RAM
(`exmaples/odocrypt/fpga/src/constraints/place.xdc`). `xdc/qmtech_xc7k325t_pinout.xdc` has no
pblocks. With 420 block RAMs per instance, 2–4 instances, and a 640-bit permutation per round, the
placer is given no reason to put round *i*'s state registers anywhere near round *i*'s block RAMs.
Each round is a self-contained 640-bit → 20-BRAM cluster, which is close to an ideal pblock
candidate, and none exist.

**It explains why the pipelined variant got *slower*.** `mux2_pipelined_transform.py` reports
`clk_2x` = 88.80 MHz against the unpipelined 103.72 — a 14% regression — and concludes the
constraint is inherent to multiplexing. Adding registers making timing *worse* is the classic
signature of a placement/congestion-bound design, not a depth-bound one: the extra registers
compete for the same congested region and push the endpoints further apart. Under the "inherent to
multiplexing" reading that regression is unexplained; under a routing reading it is expected.

The doc's conclusion — that a path into a time-multiplexed memory is capped at one `clk_2x` window
"no matter how it is registered" — is also too strong. The two slots are not symmetric. With
`phase` asserted over `clk_h` low, slot 1 is captured at t=T (a full period after `state[i]`
launches) and slot 0 at t=T/2. Only slot 0 is squeezed; slot 1 already has a full `clk_h`. The
asymmetry is what §2.3's +1-stage variant is for: reading the *previous* cycle's `state[i]` gives
slot 0 1.5 T and slot 1 2 T. That is analysis, not a measurement — but it is a different claim
from "inherent and unfixable", and it has not been tested, because the only variant tried
registered the address immediately before the BRAM, which re-launches at t=0 and reproduces the
T/2 budget it was meant to escape.

---

## 4. What to do, in order

1. **Measure the address path before designing around it.** Build with `openxc7/build.sh` (which
   now emits a post-route JSON) and run `openxc7/report_sbox_paths.py` on it. It reports, per
   round, where that round's block RAMs were placed, where the flip-flops driving their address
   pins were placed, and the worst driver→BRAM Manhattan distance. Large spread confirms §3 and
   makes floorplanning the lever; a tight spread refutes it and points back at the fabric.
   Nothing below is worth doing first.

   This deliberately uses the open-source flow: **the XC7K325T is not covered by any free Vivado
   tier** (`openxc7/README.md`), so a Tcl report is unusable for most people working on this
   board. `vivado/report_sbox_paths.tcl` does the same job and additionally gives real
   `DATAPATH_DELAY` numbers, but only if you have a licence.
2. **Floorplan one round as a probe.** Wrap a single `crypter/round<N>` — its 20 block RAMs and
   its 640 state registers — in a pblock and re-place. If the round's address delay drops, roll it
   out to all 21 and re-measure `clk_h`. This costs no RTL change and is reversible.
3. **Then retry mux2**, which needs `clk_2x` = 2 × `clk_h`. Every nanosecond taken off the address
   path is spent twice here: once on `clk_h`, once on making the muxed slot fit.
4. **If the address path is genuinely irreducible, build the +1-stage variant at T=7**, not T=4
   (§2.3). Same rate, schedulable loop, and both mux slots get a full `clk_h`.
5. **Do not spend effort tuning THROUGHPUT for rate** (§2.2). It is flat. Spend it on schedulability.

## 5. LUT-built S-boxes: confirmed too expensive, and for one more reason

`README.md` rules out spending idle logic on a 3rd instance by measuring one `sbox_large` at
**406 LUT** with `synth_xilinx -nobram`. Re-measured for this review on yosys 0.33:

```
LUT6 340    MUXF7 160    MUXF8 80        (per sbox_large, both read ports)
```

340 against their 406 — different yosys version and a different OdoCrypt epoch's tables, same
conclusion by a wide margin. The information-theoretic floor is 320 LUT6 (a 1024×10 ROM is 10,240
bits, a LUT6 holds 64, ×2 ports), so at 340 the tools are within 6% of optimal and there is no
headroom to find.

**One resource that budget misses: MUXF7/MUXF8.** Building a 10-input function needs 16 LUT6 plus
a mux tree, and the measurement shows 240 MUXF7/F8 per S-box alongside the 340 LUTs. The XC7K325T
has 101,900 MUXF7 and 50,950 MUXF8 (half and a quarter of the LUT count). Converting the 370
S-boxes a 3rd instance would need costs ~59,200 MUXF7 and ~29,600 MUXF8 — **58% of both**, on top
of the LUTs. The LUT-only budget in `README.md` reaches the right answer, but it understates how
far out of reach it is.

## 6. Smaller findings

**`openxc7/build.sh` did not run as written.** It invoked
`synth_xilinx -top … -family xc7 -json out.json`, but mainline yosys's `synth_xilinx` has `-blif`
and `-edif` and **no `-json`** (verified on 0.33), so the command aborted with "Unknown option or
option in arguments" before synthesis began. Fixed here by splitting it into
`synth_xilinx …; write_json out.json`, which works on every yosys version. If the flow ran for
you as-written, your yosys is patched or packaged differently — worth knowing either way, since
the README presents this script as the verified path.

**`FLATTEN=1` on the full miner is expensive.** yosys was killed during the FLATTEN pass on
`miner` (encrypt + keccak + miner) in a 16 GB container, while the same design synthesises fine
unflattened and a two-round wrapper flattens without trouble. nextpnr needs a flat netlist so the
flag cannot simply be dropped, but anyone hitting an unexplained yosys death mid-build should
suspect memory here rather than a design problem.

**The latency constants are correct but fragile, and §2.3/§4 would break them.** `miner.v`'s
`6'h33` (51 advances) and the wrapper's `8'hcd` (205 cycles) encode a 204-cycle pipeline latency.
Simulation confirms it exactly: 204 cycles measured, 943 consecutive results checked, zero
mismatches, nothing dropped — but with only 2–3 cycles of margin. Any change to THROUGHPUT or
unrolling silently invalidates both. `exmaples/odocrypt/fpga/src/sim/miner_latency_tb.v` measures
the latency directly; re-run it after any pipeline change rather than recomputing by hand.

**`atomminer_misc.v:130` has a replication typo.** `data_out = {data_width*1'b0}` concatenates the
*product* `data_width * 1'b0` instead of replicating: `{data_width{1'b0}}`. Both evaluate to zero
today so nothing breaks, but it stops meaning "all bits zero" the moment the module is reused at a
different width. `delreg_varbits_vardel` is instantiated from `usb3_interface.v` only, so this is
out of the Kintex build's path — worth fixing in passing.

**`clk_gen_hash.v` already emits the 2x clock**, so §2.3 and step 3 of §4 need no new clocking
work.
