# OdoCrypt miner: independent implementation review

2026-09-06. A review of the core as implemented, from first principles rather
than from what AM01 and odo-miner-cyclonev happen to do. What follows is
derived from `tools/odo_gen/odocrypt.{h,cpp}`, the generator in
`tools/odo_gen/odo_gen.cpp`, and the emitted `hdl/odocrypt/encrypt.v`.

## 1. What the hardware actually is

640-bit state as 10 × 64-bit words, 84 rounds, each round:

    pbox0 -> sboxes -> pbox1 -> linear mix -> round key

Measured from the emitted RTL, per round:

| step | implementation | cost |
|---|---|---|
| `apply_pbox0/1` | **pure wiring** — 1310 `assign out[x] = in[y]` | 0 logic, long wires |
| 40 × `sbox_small` (6→6) | LUT6 | ~240 LUT6 |
| 10 × `sbox_large` (10→10) | **BRAM, each instantiated twice** | **20 RAMB18** |
| `rotation_helper` | XOR of 6 constant rotations | ~640 LUT6 |
| round key | XOR with a 16-bit constant | ~free |

The large S-boxes are the whole story. `ApplySboxes` reads `sbox2[i]` **four
times per word per round** (at bit offsets 6, 22, 38, 54). A true dual-port
RAMB18 gives two reads per cycle, so each table is instantiated twice:

    10 tables × 2 instances = 20 RAMB18 per round stage

With `unrolling = 21` (84 rounds / THROUGHPUT 4), that is **420 RAMB18 per
miner**, and two miners fill 840 of 890.

**BRAM count is set by read bandwidth, not by capacity.** Each table is
1024 × 10 bits = 10 Kbit in an 18 Kbit block — 44% of every BRAM is wasted —
and that waste is unavoidable, because what is scarce is *ports*, not bits.

## 2. The governing law

Everything else follows from this. With `unrolling ≈ 84/T`:

    hashrate = miners × clk / T
    BRAM     = miners × 20 × unrolling = miners × 20 × 84/T

Eliminating `miners` and `T`:

    hashrate (MH/s) = BRAM × clk(MHz) / 1680

Check against the shipping build: 840 × 200 / 1680 = **100.0 MH/s**. Exact.

**`T` cancels completely.** Throughput, unrolling and miner count are not
independent levers — they are three views of one quantity. This is why
THROUGHPUT=3 was verified correct and still strictly slower, and why the
"1 wide miner vs 2 narrow miners" question was never a real choice.

There are exactly **two** ways to more hashrate: more BRAM *read bandwidth*,
or more clock. Nothing else in the design space matters.

## 3. Why it is wire-limited (and why that is structural)

`apply_pbox` emits nothing but `assign out[x] = in[y]` — a 640-bit
permutation. It costs zero logic and enormous routing. Between every pair of
pipeline stages sits a full 640-bit shuffle, twice.

That is the entire explanation for the repeatedly-measured result that
routing is 70–91% of the critical path. The algorithm was designed so that an
FPGA's cheap resources (wires, LUTs, BRAMs) do the work — the permutation
*is* the cost, and it is paid in wire.

Three independent experiments confirm you cannot buy speed by reducing logic
depth: `noabs` traded 1.8 ns of logic for 2.2 ns of routing and lost; pre-mix
pipelining v1 added 640 flops and never routed; v2 fixed that and moved the
median +0.8% while dropping the mean 10.5%. **Adding registers does not
shorten wires.** Any further RTL micro-optimisation of the datapath is
misdirected effort.

## 4. More miners: the mux, and the single number that decides it

`mux2_transform.py` time-multiplexes two S-box lookups onto one BRAM using
`clk_2x`, halving BRAM per miner (measured: **210 RAMB18**, 23%, for one
miner — the transform's inference holds under yosys as well as Vivado).

Measured scaling, from three real builds (predicts 167,587 LUT for 4 miners
against Vivado's measured 164,123 — 2% agreement):

| config | LUT | RAMB18 |
|---|---|---|
| 2 muxed | 41.2% | 47.2% |
| 3 muxed | 61.7% | 70.8% |
| 4 muxed | 82.2% | 94.4% |

Now apply the law. Muxing doubles reads per BRAM per `clk_h`, so effective
BRAM doubles, while `clk_h = clk_2x / 2`:

    stock:  hashrate = 840 × clk_h   / 1680 = clk_h   / 2
    muxed:  hashrate = 2×840 × clk_h / 1680 = clk_2x  / 2

**The mux wins if and only if `clk_2x` exceeds the stock `clk_h` — that is,
200 MHz.** Everything else about the transform is irrelevant to the decision.
And the payoff is linear and exact:

    hashrate (MH/s) = clk_2x / 2

so clk_2x = 250 MHz → 125 MH/s (+25%); 300 MHz → 150 MH/s (+50%); 400 MHz →
200 MH/s, which will not happen.

This is worth stating plainly because it collapses a large, expensive
experiment into one measurement. The stock design already clocks BRAM reads
at 200 MHz with WNS +0.763 ns (a 4.237 ns path in a 5.000 ns period). The
muxed path is the same BRAM read plus address multiplexing. So `clk_2x`
somewhat above 200 MHz is plausible, and far above it is not. Expect
**+15% to +40%**, not a doubling.

`vivado/build_mux4.tcl` is the right and only place to measure this —
nextpnr cannot time BRAM-adjacent paths at all.

## 4b. The mux, MEASURED — 2026-09-10

Section 4 said one number decides it and predicted +15–40%. Built, and it is
+31%. The build took **9 hours 23 minutes**, routed from 269,877 failed nets to
zero, and then missed timing on both clocks:

```
MUX4 RESULT -- worst slack per clock:
  clkout0_unbuf (clk_2x)  target 2.500 ns  WNS -1.323  -> needs 3.823 ns (261.6 MHz)
  clkout1_unbuf (clk_h)   target 5.000 ns  WNS -0.679  -> needs 5.679 ns (176.1 MHz)
```

Applying `hashrate = clk_2x / 2`:

    muxed  261.6 / 2 = 131 MH/s
    stock              100 MH/s        +31%

Resources came in almost exactly as section 4 predicted: **80.51% LUT** against
82.2%, **94.38% RAMB18** against 94.4%. The scaling model was right.

**Recommendation: do not ship it, and the +31% is not the reason.** The cost
attached to that gain is what decides it:

* Both clocks miss. Closing −1.323 ns on a design already at 94% BRAM and 80%
  LUT is not tuning, it is a research project — and section 3 explains why:
  routing is 70–91% of the critical path and adding registers does not shorten
  wires. There is no logic depth left to trade.
* `found_path` discards a **third simultaneous find**. It refuses NUM_MINERS > 2
  for that reason, and this build only elaborated because
  `ALLOW_LOSSY_MULTI_MINER` was set — an experiment flag that must never be set
  on a mining bitstream. Shipping means widening the collector's scan and stash
  first, with tests.
* 9½ hours per build makes iterating on it expensive in a way two-instance
  builds are not.

The experiment did its job: it turned "should we do this?" into 261.6 MHz.

---

## 4c. What 1680 is made of, and why none of it is reclaimable

    1680 = 20 × 84
         = (10 tables × 4 reads ÷ 2 ports per RAMB18) × 84 rounds

`ApplySboxes` reads each `sbox2[i]` four times per word per round, at bit
offsets 6, 22, 38 and 54. A true dual-port RAMB18 serves two reads per cycle,
so each table is instantiated twice.

Every term is fixed by something outside our control. **10 tables, 4 reads and
84 rounds are OdoCrypt. 2 ports is the RAMB18.** Checked and closed:

| idea | why not |
|---|---|
| RAMB36 instead | same two ports; a RAMB36 is two RAMB18s, so the ratio is identical |
| SDP mode for width | 36 bits wide but a **single** read port — strictly worse |
| two tables per block | 20 bits will not fit 18, and the constraint is ports anyway |
| distributed ROM | ~160 LUT per read port → 10 × 4 × 160 × 21 ≈ **134,000 LUT per miner** against 203,800. One miner where BRAM gives two |

### The mux halves it — and that is the whole point of the mux

The one term above that is NOT immutable is the ports. Time-multiplexing on
`clk_2x` gives **four effective reads per `clk_h`** instead of two, so each
table needs one block instead of two:

    stock  BRAM = miners × 20 × 84/T   ->  hashrate = BRAM × clk_h / 1680
    muxed  BRAM = miners × 10 × 84/T   ->  hashrate = BRAM × clk_h /  840

Check: 840 × 200 / 840 = 200 MH/s, which is `clk_h` — the same statement as
section 4's `clk_2x / 2`, arrived at from the other direction.

**That is why the mux is the only bandwidth lever anyone has found.** It is
also why it buys nothing for free: halving the constant costs a doubled clock
on the S-box path, and section 4b measures what that clock actually closes at
(261.6 MHz, not 400). The constant halves; the clock that pays for it does not
reach twice. Net +31%.

So the honest statement is narrower than "1680 is fixed":

* 10 tables, 4 reads, 84 rounds — **fixed by OdoCrypt**
* 2 ports per RAMB18 — **fixed by the device, unless you spend clock to
  multiplex**, which is the mux, which is measured
* the constant is not an artefact of our implementation that a cleverer
  *layout* or a different memory primitive would shrink

The four closed doors in the table above are all attempts to reduce it WITHOUT
spending clock. Every one fails. The mux succeeds at it, and then hands the
bill to the clock.

**Which reframes the Blackminer comparison.** A Blackminer F1 Mini is quoted at
260 MH/s and reviewed at **195–200 MH/s** real-world, on what is reported to be
an XC7K325T — apparently 2× this design on the same part.

    2 × 100 MH/s = 200 MH/s

The standard F1 is documented as carrying **two FPGA hashing boards**. If the
Mini likewise carries two devices, we are at **parity per chip** and there is no
factor of two hiding in the S-box implementation — which is what the law above
predicts, and what the table of closed doors independently supports.

NOT CONFIRMED: the chip count could not be established from public sources.
Recorded as a hypothesis with its arithmetic, because the alternative — that a
different S-box scheme beats the law by 2× — is worth someone checking rather
than assuming either way.

---

## 4d. Three instances, and what the timing report actually said

Section 4b measured four. Three was built to get a second point on the curve,
because one number is not a curve:

| | clk_2x | clk_h | BRAM | overlaps after place | hashrate |
|---|---|---|---|---|---|
| stock, 2 inst | — | 200.0 | 840 (94.4%) | — | 100.0 MH/s |
| mux, 3 inst | 286.45 | 176.40 | 630 (70.8%) | 7,814 | 107.4 MH/s |
| mux, 4 inst | 261.57 | 176.09 | 840 (94.4%) | 80,651 | 130.8 MH/s |

**Four instances win, and the reason is the surprise.** Section 4b predicted
three might beat four if congestion relief bought more than 33% on the clock.
It bought 9.5% on `clk_2x` — and **`clk_h` did not move at all**, 176.40
against 176.09, despite an order of magnitude fewer overlaps.

`clk_h` being flat across a 33% change in device occupancy is the direct
confirmation of section 3: the 640-bit permutation sets `clk_h`, not
congestion, so emptying the device does not speed it up. Only `clk_2x`
responded, and only slightly.

---

## 4e. The clk_2x critical path is not the S-box — it is the phase

Having two builds made it worth reading the timing report rather than just
the WNS number. The mux3 worst path on `clk_2x`:

```
Slack (VIOLATED) : -0.991ns
  Source:      odocrypt_gpio_wrapper_inst/sbox_mux_phase_reg_replica_14/C
  Destination: .../round12/sboxes/sbox20inst_sbox23inst_mux/a_q1_reg/ADDRARDADDR[6]
  Requirement:      2.500ns
  Data Path Delay:  2.766ns  (logic 0.322ns 11.6%  route 2.444ns 88.4%)
  Logic Levels:     1  (LUT3=1)

  sbox_mux_phase_repN_14_alias   fo=202   1.326ns
  a_addr[2]                      fo=1     1.118ns
```

**Over half the critical path is distributing the phase-select bit** — and
that is after Vivado has already replicated the source register fourteen
times, each replica still driving 202 loads. The actual muxing is one LUT3 at
0.322 ns. The design was not S-box limited on `clk_2x`; it was limited by
broadcasting a one-bit signal that every site can generate for itself.

### The fix, and why the objection to it does not hold

The wrapper's comment insisted on one global phase: *"two that were out of
step would drive the same table in the same clk2x window and read each
other's addresses."* That conflates **must be in step** with **must be the
same net**, and on inspection neither half survives:

* A toggle flop with `INIT=0`, clocked by `clk_2x`, with no enable and no
  reset **cannot** drift from another one. They start identical at
  configuration and flip on identical edges. Lockstep is a property of the
  construction, not of the wire.
* Lockstep is not even required. Each muxed box instantiates its **own**
  `mem` — no two boxes share a table — and nothing outside a box reads
  `phase`. A box out of step with its neighbours is simply that box with an
  inverted phase, which `sim/run_encrypt_equiv.sh`'s `+pinv=1` run already
  **measures** as a benign relabelling.

So `tools/mux2_transform.py` now emits the phase inside each box: two
hand-replicated `DONT_TOUCH` flops, one for each address mux, at fanout ~11
instead of 202. Cost is ~1,680 flops of 407,600, or **0.4%**.

`DONT_TOUCH` is load-bearing, not decoration. Without it these are 840
sequential elements with identical behaviour, and Vivado's
equivalent-register removal is entitled to merge them straight back into the
one net the change exists to delete. It is applied by hand to both copies
because the same attribute also stops the tool replicating them itself.

### What this is worth, stated as a prediction

Removing 1.326 ns of pure route leaves ~1.44 ns of data path. Where the next
critical path lands is **unknown** — it may be somewhere else entirely and
cap the clock well below the arithmetic below. But the ceiling being chased:

    hashrate = BRAM × f_bram / 1680        (section 4c: /840 when muxed)

    840 BRAM at the RAMB18 -1 limit (~388 MHz)  ->  194 MH/s

Against the 130.8 MH/s that four muxed instances measure today, and 100 MH/s
shipping. **If it reached the BRAM limit that is the factor of two that
sections 3, 4c and 6 could not find anywhere else** — and unlike every
closed door in those sections, it costs no extra bandwidth, no extra
latency and no extra block RAM. Landing halfway is still +25% on top of the
+31%.

### MEASURED, 2026-09-11 — +16.8% on clk_2x

Built (12h46m, against 9h23m for the broadcast version) and proved equivalent
first: 439 defined cycles bit-identical, with the negative control failing all
439.

```
                      clk_2x        clk_h cap     hashrate
shipping, 2 inst         —          200.0 MHz     100.0 MH/s
mux4, broadcast       261.57 MHz    176.09        130.8 MH/s
mux4, LOCAL phase     305.53 MHz    175.53        152.8 MH/s
```

`clk_2x` is what binds — the MMCM derives `clk_h = clk_2x / 2`, and 152.77 is
well under the 175.53 that `clk_h`'s own paths would allow. So the muxed
hashrate is `clk_2x / 2`, as section 4b had it.

**+16.8% over the broadcast phase, +52.8% over the shipping bitstream.** Cost
was 1,680 flops: LUTs went 80.51% → 81.37%, block RAM unchanged at 94.38%.

The congestion price was real but paid in build time rather than in the
result: peak overlaps rose 80,651 → 103,039 and one global routing iteration
took 2h50m. It converged.

### The path moved — but only by one hop

The new `clk_2x` critical path, at 2.462 ns of a 2.500 ns budget:

```
Source:      .../round17/sboxes/sbox20inst_sbox23inst_mux/phase_b_reg/C
Destination: .../round17/sboxes/sbox20inst_sbox23inst_mux/a_q1_reg/ADDRBWRADDR[12]
Logic Levels: 1  (LUT3=1)

  phase_b_reg/Q  FDRE            0.269ns   SLICE_X24Y99
  net phase_b    fo=11, routed   1.344ns   <-- still the phase
  LUT3                           0.053ns   SLICE_X23Y110
  net b_addr[8]  fo=1,  routed   0.796ns
  RAMB18                                   RAMB18_X1Y47
```

Same source and destination *inside one box* now — no cross-chip broadcast
left. But **the phase net is still 1.344 ns at fanout 11**, because the placer
put the flop at `Y99` and the LUT3 that reads it at `Y110`, eleven rows away.
At 94% block RAM and 81% LUT there may simply be no slice free beside the
BRAM.

So this is no longer a fanout problem, it is a **placement** one, and the
obvious next step is to remove the placer's freedom to get it wrong:
replicate the phase flop **per address bit** rather than per port. Each of the
ten LUT3s per port then has its own fanout-1 flop that can pack into the same
slice. Cost rises to ~16,800 flops (4.1% of registers), still cheap.

Rough arithmetic: if that net fell to ~0.1 ns the path would be ~1.22 ns
against a 2.5 ns budget — at which point something else entirely becomes
critical, and the RAMB18's own ~388 MHz is the backstop (194 MH/s). NOT a
prediction: two builds have now moved the critical path without either
landing where the previous one's arithmetic suggested.

### Still not shippable, for the reason section 4b gave

`WHS` is **negative on both clocks** (-0.379, -0.412) — as it was on the
broadcast mux4 (-0.393) and mux3 (-0.338). Hold violations do not go away by
slowing the clock. That, plus `found_path` discarding a third simultaneous
find unless `ALLOW_LOSSY_MULTI_MINER` is set, is what stands between this
number and a bitstream worth flashing.

### Testing it required repairing the test first

`run_encrypt_equiv.sh` drove its negative control through the `phase` **port**
(`+pstuck=1`). A box that generates its own phase ignores that port, so the
run that MUST FAIL would have started passing — quietly turning the control
into a rubber stamp and making the positive run's PASS worthless. The
configurations are compile-time now, one binary each:

```
(no define)             local phase, as shipped     -- must PASS
-DMUX_PHASE_STUCK       local phase held at 0       -- must FAIL
-DMUX_PHASE_FROM_PORT   broadcast phase, +pinv=1    -- expected to pass
```

The third also keeps the revert honest: the broadcast design is one `-D`
away, not a regeneration, and the run proves it still builds a working core.

---

## 4f. Where the remaining speed is — reviewed 2026-09-11

### First, a correction: the ceiling is 175.5 MH/s, not 194

Section 4e said the mux was chasing ~194 MH/s, from the RAMB18's ~388 MHz
rating. That is the ceiling on `clk_2x` alone. It is **not** the first limit
the design meets, because the muxed hashrate is:

    hashrate = clk_h = min( clk_2x / 2 , whatever clk_h's OWN paths close at )

and the second term is measured at **175.53 MHz** (`clkout1_unbuf`, WNS
-0.697 against a 5.000 ns target). So:

```
clk_2x    | clk_2x / 2 | clk_h paths | hashrate
261.57    |   130.8    |   176.09    |  130.8     mux4, broadcast phase
305.53    |   152.8    |   175.53    |  152.8     mux4, local phase  <- today
351.06    |   175.5    |   175.53    |  175.5     the crossover
400.00    |   200.0    |   175.53    |  175.5     clk_h now binds
388 (BRAM)|   194.0    |   175.53    |  175.5     and still binds
```

**Above `clk_2x` = 351 MHz, further `clk_2x` work buys nothing.** The honest
ceiling for this architecture on this part is **175.5 MH/s (+75% on shipping)**,
and the last 15% of it needs `clk_h` work, not more phase tuning.

Worth knowing now rather than after another 12-hour build.

### Lever 1 — finish the clk_2x job (152.8 -> 175.5, +15%)

Needs `clk_2x` 351. Today 305.53, so a further +15% on a path that is 86–88%
routing. Two things to spend:

* **Per-address-bit phase replication.** Building 2026-09-11. Targets the
  1.344 ns fanout-11 phase net directly; see 4e.
* **Register the muxed address — and pay for it with a stage already there.**
  The remaining path after the phase net is
  `LUT3 -> b_addr[8] (0.796 ns) -> RAMB18`. Putting a register between the
  mux LUT and the block RAM splits that path in two. It normally costs a
  cycle, which would break the latency match that section 4e's generator is
  careful to preserve — but the muxed box ALREADY carries a shift register
  (`a_q1..a_q3`) whose only job is padding latency to the stock core's
  2 clk_h. Move one stage from after the BRAM to before it and the total is
  unchanged at four clk2x stages. Cost is 20 flops per box, the same order as
  the phase replication, and no latency change at all.

  NOT YET TRIED. The phase chain feeding the output demux has to be realigned
  by the same one stage or the demux selects the wrong slot — which is the
  class of bug that produced permanently-X output on 2026-09-04.

### Lever 2 — clk_h, which is the actual ceiling

`clk_h`'s worst path is not the permutation this time:

```
Source:      .../round16/sboxes/sbox56inst_sbox59inst_mux/s0_a_out_reg[0]/C
Destination: .../crypter/state_reg[17][38]/D
Data Path Delay: 2.701ns  (logic 0.375ns 13.9%  route 2.326ns 86.1%)
Logic Levels: 2  (LUT2=1 LUT6=1)
```

The source is a muxed box's **output register, which is clocked on `clk_2x`**,
and the destination is the state register on `clk_h`. So the binding `clk_h`
path is a `clk_2x` -> `clk_h` handoff created by the mux itself, not by
OdoCrypt. 2.701 ns of data against a 5.000 ns period, and it still misses —
the launch edge is a `clk_2x` edge, so the path does not get the full `clk_h`
period.

That suggests the demux output registers want to be on `clk_h`, or to be
followed by a `clk_h` re-register, so the permutation sees a full period.
Both change latency and both need the equivalence gate. UNMEASURED, and it is
the only idea here that attacks the 175.5 ceiling rather than the gap to it.

Note this is a mux-specific path. Section 3's finding that `clk_h` is
wire-limited by the 640-bit permutation still stands for the STOCK design,
and mux3-vs-mux4 confirmed it (176.40 vs 176.09 across a 33% change in
occupancy). What is new is that in the MUXED design something else got there
first.

### Lever 3 — the 50 spare block RAMs

840 of 890 are used, 420 tiles of 445. The remaining 50 RAMB18 would be
+6% if they could be filled, but a fifth miner needs 210. Dead end at this
granularity; noted so it is not re-examined.

### Lever 4 — silicon

An XC7K325T in a **-2** speed grade is roughly 10–15% faster on the same
netlist, and unlike everything above it needs no RTL, no equivalence run and
no 12-hour build. It costs money and a board swap. Mentioned because at some
point it is cheaper than engineering time.

### What is NOT a lever, restated

`THROUGHPUT` and unrolling cancel out of the law (section 2). More instances
do not raise `clk_h` (mux3 vs mux4). Reducing the 1680 constant needs the
mux, which is already taken (4c). Configurable epochs cost 78% (section 5).

### And the two things that gate ANY of this reaching the board

1. **Hold violations.** -0.048 ns and -0.132 ns, flop-to-flop on one clock,
   so caused by skew and NOT fixed by slowing the clock. Every muxed build
   has them; no shipping build does.
2. **`found_path` drops a third simultaneous find** unless
   `ALLOW_LOSSY_MULTI_MINER` is set, which is an experiment flag.

A faster number that cannot be flashed is worth less than 15% on one that
can. If the per-bit build lands well, these two are the next work, not
another clock experiment.

---

## 4g. The hold violations, diagnosed — 2026-09-12

Chased before spending another 15-hour build, on the grounds that if they are
unfixable then every clock experiment above is moot. They are diagnosable, and
the answer reframes the whole mux effort.

### They are almost entirely on the clk_h <-> clk_2x boundary

```
Intra Clock Table
  clkout0_unbuf (clk_2x)   WNS -0.447   hold failing:     7 of 119,379
  clkout1_unbuf (clk_h)    WNS -0.194   hold failing:    12 of 129,278

Inter Clock Table
  clkout1 -> clkout0       WNS -0.595   hold failing: 5,937 of  16,800
  clkout0 -> clkout1       WNS -0.480   hold failing: 6,608 of  53,676
```

**12,545 of the 12,564 failing hold endpoints are crossings between the two
clocks.** Intra-clock hold is 19 endpoints and essentially clean.

The same is true of setup. The design's reported WNS of -0.595 is an
INTER-clock number; the intra-`clk_2x` path I have been optimising for two
builds is -0.447. The phase work was real and the frequency gains are real,
but the binding constraint was never the S-box address path.

### The mechanism: two BUFGs with different insertion delays

A representative failing hold path, clk_2x launching into clk_h:

```
Data Path Delay:     0.193ns
Clock Path Skew:     0.331ns (DCD - SCD - CPR)
  Destination Clock Delay (DCD):  4.956ns   BUFGCTRL_X0Y0  bufg_clk_h
  Source Clock Delay      (SCD):  4.084ns   BUFGCTRL_X0Y1  bufg_clk_2x
  Clock Pessimism Removal (CPR):  0.542ns
```

The data takes 0.193 ns. The clock edge it races takes 0.331 ns longer to
arrive at the destination than at the source. Data wins the race, which is
exactly what a hold violation is. `clk_h` and `clk_2x` leave the same MMCM
and then travel through **two different BUFGs** on two different global
networks, one of them carrying 55,538 loads.

### Why a phase shift will not rescue it

The obvious cheap fix is `CLKOUT1_PHASE` — shift `clk_h` to cancel the
offset. It does not work, and the table above says why: **both directions
fail hold.** `clkout1 -> clkout0` and `clkout0 -> clkout1` are each losing
the race, which a single global offset cannot both fix. Insertion delay
varies by die location across a 55,538-load network, so the skew is
position-dependent in sign, not a constant.

Nor is it congestion alone. mux3 sat at 70.8% block RAM with room to spare and
still reported -0.338.

### The structural fix: one clock and a clock enable

Delete the second clock domain. Run everything on `clk_2x`, and give the
former `clk_h` registers a clock enable that is high every other cycle.
Then:

* all 70,476 crossings become ordinary same-clock paths, and the BUFG skew
  that causes the hold failures no longer exists on them;
* the permutation logic still gets two `clk_2x` periods, declared as
  `set_multicycle_path 2 -setup` / `1 -hold` rather than implied by a second
  clock;
* `bufg_clk_h` disappears entirely.

Arithmetic for the prize, if the inter-clock paths go away and the intra-clock
ones stay where they are: WNS becomes -0.447, achievable period 2.947 ns,
`clk_2x` **339.3 MHz -> 169.6 MH/s**, and the hold failures that stop it being
flashed go with it.

NOT a small change. Every former `clk_h` register needs the enable, the
enable itself is a high-fanout net with the same distribution problem the
phase had (though a multicycle path gives it far more slack), and the
transform, the wrapper and the XDC all move together. It is, though, the
first idea in this whole line of work that attacks the thing the reports have
been pointing at all along.

### What this says about 4e and 4f

The per-port and per-bit phase work stands: `clk_2x` went 261.57 -> 305.53 ->
323.10 and those are real, measured, equivalence-proved improvements. But
section 4f's lever ordering was wrong. It ranked "finish the clk_2x job"
first on the strength of a critical path that turns out to be the SECOND
worst thing in the design. The clock-enable rewrite outranks both remaining
levers there, because it is the only one that also removes the reason none of
this can be flashed.

---

## 4h. CLOCK_DELAY_GROUP + MMCM retune, MEASURED — 2026-09-13

Built with the phase per address bit, `CLOCK_DELAY_GROUP` on the two hash
clock nets, and the MMCM finally set to what the design closes at
(MULT 19 / DIVIDE_2X 3 -> clk_2x 316.67, clk_h 158.33).

### Setup: solved

```
                     WNS(ns)   failing endpoints
intra clkout0        +0.151         0 of 119,341     (was -0.447, 2,098)
intra clkout1        +0.054         0 of 129,444     (was -0.194,     5)
clkout1 -> clkout0   -0.052        10 of  16,800     (was -0.595, 16,049)
clkout0 -> clkout1   +0.065         0 of  53,676     (was -0.480, 30,160)
```

**47,128 failing setup endpoints became 10**, and the worst is -0.052 ns —
one rung down the MMCM ladder (MULT 18.5, clk_2x 308.33) closes it outright.
Most of that is the honest clock target rather than the constraint; the
previous builds were being asked for 400 MHz while closing at 305-323.

### Hold: NOT solved, and the constraint is exhausted

```
                     WHS(ns)   failing endpoints
clkout1 -> clkout0   -0.357        4,451 of 16,800   (was -0.356, 5,937)
clkout0 -> clkout1   -0.398        3,343 of 53,676   (was -0.413, 6,608)
intra (both)         -0.089/-0.068    13             (was 19)
```

Failing endpoints fell 38% (12,564 -> 7,807), but **the worst slack did not
move**, and the worst path says exactly why:

```
Source:      .../round11/sboxes/sbox20inst_sbox23inst_mux/s1_b_out_reg[2]/C
Destination: .../crypter/state_reg[12][308]/D
Data Path Delay:  0.197ns
Clock Path Skew:  0.332ns    <-- was 0.331ns before CLOCK_DELAY_GROUP
```

0.332 against 0.331. The constraint balanced enough paths to retire a third
of the failures and it halved the clock networks' absolute insertion delay
(DCD 4.956 -> 4.995 on this path but ~2.5 ns on many others), yet the
worst-case skew between the two BUFG networks is untouched.

**So rung 2 is dead.** The ladder, for the record:

| rung | cost | result |
|---|---|---|
| post-route hold fix | 1h | -0.413 -> -0.413, not one picosecond |
| CLOCK_DELAY_GROUP | 1 property + 15h | 38% fewer endpoints, worst slack unmoved |
| clock-enable rewrite | ~30h, high risk | untried, and now the only candidate |

Both cheap rungs are spent, and neither was wasted: they cost about 16 hours
of machine time between them to rule out two explanations that would each
have made the rewrite unnecessary. The rewrite was never going to be started
on the strength of a guess.

### What this leaves

Everything except hold is now in place for a flashable four-instance
bitstream: the RTL is equivalence-proved (4e), `found_path` keeps every
simultaneous find since 2026-09-12, `ALLOW_LOSSY_MULTI_MINER` is gone, and
setup is one MMCM rung from clean at **158.3 MH/s, +58%**.

The single remaining blocker is 7,807 hold endpoints, 7,794 of them on
clk_h <-> clk_2x crossings, caused by 0.332 ns of skew between two BUFG
networks that no constraint has been able to close. Section 4g's conclusion
stands and is now the only route: delete the second clock domain, run
everything on `clk_2x`, and gate the former `clk_h` registers with a clock
enable.

Its unsolved problem, stated so it is not discovered halfway: the CE net has
a quarter of a million loads, and the local-generation trick that fixed the
phase (4e) does NOT transfer, because a CE flop toggles every cycle and so
gets no multicycle relief. That needs an answer before the rewrite starts.

---

## 5. Epoch renewal on the board

**Do not do it by making the cipher runtime-configurable.** The reason is the
same fact that makes the design fast: the epoch-dependent parts are *wiring*.

Per epoch, `OdoCrypt(key)` randomises the S-boxes (BRAM contents — loadable),
but also the two P-boxes' masks and rotations, the linear-mix rotations, and
84 round keys. Those are constant-folded into routing. Making them
configurable replaces free wire with barrel shifters and mask muxes:

- rotations: 5 subrounds × 5 words × 2 pboxes = 50 × 64-bit barrel rotate per
  round ≈ 13,000 LUT6
- masked swaps: 6 subrounds × 640 bits × 2 pboxes ≈ 7,700 LUT6

≈ 20,000 LUT6 per round × 21 stages ≈ **420,000 LUTs — over twice the
device**, for one miner. To fit, unrolling must fall to ~10, i.e. T ≈ 9, and
by the law of §2 the result is roughly **22 MH/s against today's 100**.

A configurable OdoCrypt core costs about 78% of the hashrate. That trade is
never worth taking.

**The right answer is already scoped in `INSTALL.md`.** Epochs are
deterministic — the key is `ntime - ntime % 864000` — so the next bitstream
can be built days ahead, and `tools/check-epoch.sh` plus the
`DO-NOT-FLASH-BEFORE` artifact convention already assume this. What is
missing is only the delivery path, and the constraint is electrical, not
algorithmic: no CM4 GPIO reaches the FPGA's dedicated configuration pins, so
the Pi cannot program it.

Two routes, both noted in `INSTALL.md`:

1. Leave a USB-JTAG adapter in one of the board's USB-A ports. Trivial, works
   today, needs no HDL.
2. **STARTUPE2/ICAPE2 self-reconfiguration** — after configuration the fabric
   *can* reach the SPI config pins, so the Pi streams a prebuilt bitstream
   over the existing GPIO bus and the FPGA rewrites its own flash. This is the
   genuinely autonomous answer. It needs a MultiBoot golden image, because a
   failed write would otherwise leave the board recoverable only by JTAG.

Route 2 is the one worth building, and note what it does *not* require: no
change to the cipher core at all.

## 6. Dead ends — checked, so they are not retried

**Packing two tables per BRAM.** Two 10-bit tables need 20 bits; RAMB18 is
18 bits wide. RAMB36 at 1024×36 holds three tables but serves them at one
address per port, and the lookups are at unrelated addresses. SDP 512×36
returns two entries per read, but only for addresses differing by exactly 512
(or an adjacent pair), which the algorithm does not give. There is no packing
win — the constraint is ports.

**S-boxes as LUTs.** A 10→10 table is ten 10-input functions ≈ 18 LUT6 each
≈ 180 LUT6 per instance. Per round that is 40 instances × 180 = 7,200 LUT6;
across 21 stages ≈ 150,000 LUTs for **one** miner's large S-boxes. Freeing
one BRAM costs ~400 LUT6, so trading enough BRAM for a third stock miner
(370 BRAM) costs ~148,000 LUTs on top of 3 × 37,000 base — about 259,000
against a 203,800 device. It does not fit. The mux achieves the same BRAM
halving for ~13% more LUTs, which is roughly thirty times cheaper.

**Reducing rounds, throughput tricks, wider miners.** All excluded by §2:
84 rounds is consensus, and `T` cancels.

## 7. The placement idea — proposed, then measured, then withdrawn

An earlier draft of this review proposed absorbing the permutation into the
*placement* of the pipeline registers: since the same two P-boxes are applied
every round, place stage *n+1*'s bit where the permutation sends stage *n*'s
bit and the wire becomes short by construction. The word shuffle is
`word → word × 3 mod 10`, with cycles `(1 3 9 7)` and `(2 6 8 4)`; the
rotations are constants. Both look absorbable.

**I measured it, and it does not work.** The reasoning below is kept because
the failure is more informative than the proposal.

### First check: is the structure still there after composition?

No. Counting how many of each word's 64 bits land in each destination word:

    pbox0, source word 0 -> [7, 10, 3, 7, 5, 7, 7, 8, 4, 6]
           source word 4 -> [10, 9, 6, 4, 9, 8, 4, 6, 4, 4]

Essentially uniform at 64/10 = 6.4. Each `apply_pbox` is the composition of
six subrounds of *masked swap → word shuffle → rotation*, and the masked swaps
use random 64-bit masks. Six rounds of that destroys the tidy word-shuffle
structure completely. No word-level layout can help, because every word talks
to every other word equally.

### Second check: cycle structure, which is what layout cost really depends on

Randomness alone would not have settled it. A permutation costs wire relative
to a layout, and even a "random-looking" permutation that is one long cycle can
be laid out around a ring so every element moves by exactly one slot.

    pbox1 o pbox0:  8 cycles, longest 228, lengths [228, 222, 88, 66, 27, 4, 3, 2]

Long cycles — so a cycle-order layout should make the permutation nearly free.

### The measurement

Model: one round maps register bits to register bits by `comp = pbox1 ∘ pbox0`
(the S-box is position-wise the identity — it permutes *values*, not
positions). The linear mix then XORs six constant rotations of each word
(measured amounts: 30, 51, 24, 23, 61, 60). Cost is total wirelength over a
1-D layout, which is the right question to ask of *any* relabeling.

| layout | permutation | linear mix | total |
|---|---|---|---|
| natural (bit *i* at slot *i*) | 135,052 | 80,180 | **215,232** |
| cycle-order | **1,264** | 818,694 | 819,958 (+281%) |
| annealed on the true cost | — | — | **184,540 (−14.3%)** |

The idea works exactly as claimed on the term it targets: cycle-order makes
the permutation **107× cheaper**. And it is a **3.8× net loss**, because the
linear mix has **3,840 wires against the permutation's 640**. Optimising the
minority term by wrecking the majority term is a bad trade, and the natural
layout already keeps the linear mix local — its taps stay inside one 64-bit
word.

Two further readings of that table:

- The natural layout's permutation cost of 135,052 over 640 wires is 211 per
  wire, against the 640/3 ≈ 213 expected for a *uniformly random* permutation
  on 640 slots. The permutation is, for layout purposes, indistinguishable
  from random.
- Annealing on the real combined cost finds only **−14.3%** (reproducible:
  −14.3% and −14.1% from two seeds). So the natural layout is already within
  about 15% of what any relabeling achieves. There is no large win hiding in a
  middle ground between the two extremes.

### Why this was always going to fail

OdoCrypt's permutation exists to diffuse. A permutation that could be made
*local* by any relabeling is one whose bits stay near their neighbours — which
is precisely a permutation with poor diffusion. **The wire cost is not an
implementation artifact; it is the algorithm's diffusion requirement expressed
physically.** Any layout that made the wiring cheap would correspond to a
weaker cipher. This is a floor, not an inefficiency, and no placer — annealing,
analytic, or algebra-derived — can go under it.

### A correction to my own earlier argument

The first draft cited the 36% seed spread (145–197 MHz on an identical
netlist) as "the size of the prize" for better placement. That was wrong. The
spread is *variance in outcomes* — routing luck and congestion on the critical
path — not evidence that a systematically better layout exists. The measured
headroom for a better layout is the −14.3% above, in total wirelength, which
is not the same quantity as Fmax and would translate to considerably less.

### What, if anything, survives

Only a weak version: feeding the placer an algebra-derived *initial* placement
might reach a good layout faster or more reliably than annealing from naming
heuristics, and might narrow the seed spread rather than raise its ceiling.
That is a tooling convenience, not a hashrate lever, and on a 14% wirelength
budget it is not worth building. **Recommend dropping this line.**
## 8. Recommendation

1. **Measure `clk_2x` in Vivado** (`build_mux4.tcl`). One number decides
   whether four muxed miners beat two stock ones: is it above 200 MHz?
   Expect +15–40%, not a doubling.
2. **Build ICAPE2 self-reconfiguration with a MultiBoot golden image** for
   autonomous epoch renewal. It touches no cipher logic, and epochs are
   predictable so bitstreams can be built ahead.
3. **Do not** make the cipher configurable, convert S-boxes to LUTs, or
   pipeline the datapath further. Each is quantified above as a loss.
4. **Do not pursue the placement idea of §7.** It was measured and refuted:
   cycle-order layout makes the permutation 107x cheaper and is a 3.8x net
   loss, and the best layout any relabeling reaches is only 14% better than
   the naive one.
