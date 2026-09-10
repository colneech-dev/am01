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

So the constant is not an artefact of our implementation that a cleverer one
would shrink. It is the algorithm meeting the device.

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
