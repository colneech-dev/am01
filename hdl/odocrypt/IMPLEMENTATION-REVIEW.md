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

## 7. The one idea I think is genuinely new

The permutation is not arbitrary — it is highly structured, and the structure
is *known to the generator*:

- **Word shuffle** is `word → word × 3 mod 10`, whose cycle structure is
  `(1 3 9 7)`, `(2 6 8 4)`, with 0 and 5 fixed — two 4-cycles.
- **Rotations** are constant cyclic shifts within 64-bit words.
- **Masked swaps** act between fixed word *pairs*.

A permutation costs wire only relative to a *layout*. Because the same two
P-boxes are applied every round, a layout that is good for one stage is good
for all of them — and the constant rotations and the word shuffle can be
**absorbed into the physical placement of the pipeline registers**: place
stage *n+1*'s bit where the permutation sends stage *n*'s bit, and the wire
becomes short by construction rather than by luck.

That is a sharper version of the "derive a floorplan from netlist structure"
idea already recorded: don't derive it from the netlist, derive it from the
**algebra**, which `odo_gen` has in hand and currently discards. `odo_gen`
could emit placement constraints alongside the RTL — placing the 10 words in
multiplicative-cycle order so the shuffle is a neighbour hop, and offsetting
each stage's bit placement by the accumulated rotation.

**The honest obstruction:** the linear mix XORs six *different* rotations of
the same word, so six bits at unrelated distances must meet at one LUT. That
term cannot be made local, and it sets a floor. The BRAM sites are fixed too,
which constrains the layout around the S-boxes. So this would not eliminate
the routing cost — but the design is 70–91% routing, the placer currently
discovers its layout by annealing from naming heuristics, and the seed spread
of **36% (145–197 MHz on an identical netlist)** is direct evidence that
placement quality, not the netlist, is what sets the clock. That spread is
the size of the prize.

This is speculative and unmeasured. It is also the only remaining idea I can
see that attacks the actual binding constraint.

## 8. Recommendation

1. **Measure `clk_2x` in Vivado** (`build_mux4.tcl`). One number decides
   whether four muxed miners beat two stock ones: is it above 200 MHz?
   Expect +15–40%, not a doubling.
2. **Build ICAPE2 self-reconfiguration with a MultiBoot golden image** for
   autonomous epoch renewal. It touches no cipher logic, and epochs are
   predictable so bitstreams can be built ahead.
3. **Do not** make the cipher configurable, convert S-boxes to LUTs, or
   pipeline the datapath further. Each is quantified above as a loss.
4. If §7 appeals, the cheapest test is to have `odo_gen` emit word-order and
   per-stage rotation-offset placement hints and re-run a seed sweep. A
   result anywhere in the upper half of the existing 145–197 MHz spread,
   *reliably* rather than by seed luck, would be the proof.
