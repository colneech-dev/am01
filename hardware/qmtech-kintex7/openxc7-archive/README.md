# openXC7 archive — frozen 2026-09-05

The open-source FPGA flow (yosys → nextpnr-xilinx → prjxray) for the AM01
OdoCrypt miner on the QMTECH XC7K325T. **Work on this flow stopped on
2026-09-05 in favour of Vivado.** Everything needed to pick it up again is
here.

Nothing was deleted. The live working directory `../openxc7/` still holds all
of it plus ~26 GB of build outputs; this archive is the ~2 MB of it that is
worth keeping and referencing.

---

## Why it was stopped

Not because the flow failed — it works, and produces a routed, timing-clean
bitstream. It was stopped because **it cannot answer its own key question.**

| | miners | clk_h | hashrate | on hardware |
|---|---|---|---|---|
| Vivado (shipping) | 2 | 200.00 MHz | **100.0 MH/s** | flashed, earning |
| openXC7 (best seed) | 1 | 197.43 MHz | 49.4 MH/s | never flashed |

openXC7 reaches **~49% of Vivado**, and almost none of that gap is the clock —
the clocks are within 1.3%. The gap is **the second miner**.

The only route to more instances is the mux2 transform (share each pair of
S-box BRAMs, time-multiplexed on clk_2x). But **nextpnr cannot time paths
adjacent to a block RAM on this architecture** — which is exactly the muxed
address path. So even a successful mux route in this flow yields a clk_h
number that cannot be trusted for the one thing that decides whether the mux
is worth doing. That is a boundary of the tool, not a bug to fix, and it is
why the mux4 experiment lives in `../vivado/build_mux4.tcl`.

---

## What is in here

| directory | contents |
|---|---|
| `docs/` | 15 research and results documents — **start with `RESULTS.md`** |
| `tools/` | 25 Python transforms, floorplanners, verifiers, yosys scripts |
| `scripts/` | 61 build and experiment runners (`build.sh` is the core one) |
| `results/` | measurement data (`seed_ab_results.tsv` is the seed/Fmax table) |
| `nextpnr-patches/` | **4 patches against nextpnr-xilinx that exist nowhere else** |
| `rtl/` | throughput variants and the 1-miner muxed top |
| `sim/` | equivalence testbenches (also live in `../sim/`) |

### `nextpnr-patches/` — read this before anything else

These are ~956 lines of modifications to nextpnr-xilinx that lived only in a
working tree at `/home/colin/src/nextpnr-xilinx-heatmap` (branch
`congestion-aware-placement`, based on `69f1eaf5`). They are **not** in this
repo's history and would have been lost with that directory. Apply with
`git am`. They cover native floorplanning, a global-net predicate, router2
criticality instrumentation, and congestion-aware placement.

Every openXC7 number in `docs/` was produced with these applied. A stock
nextpnr-xilinx **will not reproduce them**.

---

## The findings that matter — so they are not re-derived

Each of these cost real time. `docs/RESULTS.md` has the full evidence.

**Two miners is not achievable in this flow.** Closed after seven approaches
(balanced floorplan, `placer-heap-beta` both directions, TILE_NETS/WIRE_DEMAND,
CONGESTION_MAP at two weights, `--lutram`, congestion-aware placement, coarse
global routing). The design sits at 840/890 RAMB18 (94%) and the floorplan
BEL-pins every one, so no spreader can move them. The bottleneck is BRAM
egress from fixed sites.

**`--freq` does not drive place-and-route here.** Re-routing the same netlist
with `--freq` as the only variable gives *bit-identical* traces. Both clock
domains fall back to the same `target_freq`, so changing it scales all slacks
uniformly and leaves the criticality *ranking* unchanged. It is a pass/fail
grading threshold only — tightening it cannot buy Fmax.

**Seed choice dominates everything.** On an identical netlist, Fmax ranges
145.14 → 197.43 MHz — a **36% spread**, far larger than any RTL change ever
attempted here. Some seeds *diverge* rather than converge slowly (seed 9 went
88 → 220 overuse and ran 3h50m), so always cap a seed run.

**The design is wire-limited, not logic-limited.** Routing is 70–91% of the
critical path. Three independent confirmations: the `noabs` experiment traded
1.8 ns of logic for 2.2 ns of routing and lost; pre-mix pipelining v1 added
640 flops and never routed; v2 fixed that and still moved the median only
+0.8% while dropping the mean 10.5%. **Do not attempt datapath
micro-optimisation again.**

**Hashrate is proportional to BRAM consumed.** `BRAM = miners × 20 ×
unrolling`, `hashrate = miners × clk / T`, `unrolling ≈ 84/T` — the terms
cancel. 2 miners at T=4 and 1 miner at T=2 are the same 840 BRAM and the same
hashrate. So the miners-vs-throughput trade gains nothing, and THROUGHPUT=3
(verified correct, `rtl/miner_t3.v`) is strictly slower than the shipping
build.

**200 MHz is the clock ceiling in both flows.** VCO = 50 × 24 = 1200 MHz is
exactly the -1 grade maximum; MULT 25 needs 1250 MHz, and CLKOUT_DIVIDE_2X=2
would put clk_2x at 600 MHz. Further hashrate must come from more instances.

**The pinned RTL is stale, and it matters.** `rtl_sources.sh` pins at afa4b22
(2026-08-30), whose `clk_gen_hash.v` is still `CLKFBOUT_MULT = 16` — 133.33
MHz. A bitstream from this flow today would run at 133.33 MHz, not the ~197
MHz its own timing certifies, throwing away a third of the clock. This is
**not** a sign-off bug (`FREQ=133.33` is correct *for that core*), but any
resumption should bump the pin first. `rtl_sources.sh` requires re-measuring
every reference number after a bump.

---

## Where the mux experiment got to

Genuinely unfinished, and the most promising thread if this is ever resumed.

**Fit is confirmed.** One mux2-transformed miner synthesises to **210 RAMB18
(23%)** against 420 stock — the transform's BRAM inference holds under yosys,
not just Vivado. Measured, not projected:

| config | LUT (of 203,800) | RAMB18 (of 890) |
|---|---|---|
| 2 muxed miners | 41.2% | 47.2% |
| **3 muxed miners** | **61.7%** | **70.8%** |
| 4 muxed miners | 82.2% | 94.4% |

Derived from three real builds; predicts 167,587 LUTX for 4 miners against
Vivado's measured 164,123 — **2% agreement**. Three muxed miners is the
interesting point: neither resource saturated, and it needs only clk_h ≥ 66
MHz to beat the current 49.4 MH/s.

**Routing is the open problem.** Two things are required and both were learned
the hard way:

1. **The floorplan must stay ON.** `floorplan_brams.py` handles the muxed
   netlist fine (it assigns all 210 BEL attributes). Disabling it because the
   device is no longer BRAM-saturated cost ~14× in congestion — overuse 6,723
   at iter 15 without it versus 461 at iter 34 with it.
2. **Fanout must be replicated.** The route dies on
   `sbox_mux_phase` — the multiplexing phase signal, **4,202 loads from a
   single driver** spanning half the die. `tools/replicate_fanout.py` splits it
   (7 drivers over threshold, 114 replica cells). A route with floorplan +
   replication was still in placement when work stopped, so **whether the muxed
   design routes at all in openXC7 is unanswered.**

Note `tools/measure_fanout_nets.py` did **not** report `sbox_mux_phase`: it
only considers nets whose driver has a placed BEL, and only the 210 BRAMs are
placed. It will hide this class of problem again.

---

## Things that are wrong, or were, and should not be trusted blindly

**`tb_outreg_equiv.v`'s negative control was inert** until 2026-09-05. It
corrupted the *shared* input, so both cores saw the same bad data, produced
identically-changed digests, and still agreed — `+brk` could never fail. It
reported `PASS/PASS`, which by this project's own rule is **WORTHLESS, not a
pass**. Fixed here and in `../sim/` so the perturbation reaches only the core
under test. Any earlier OUTREG equivalence claim predates that fix.

**Never quote a `Max frequency` line without checking it follows a converged
`overuse=0` iteration.** nextpnr prints a pre-route SA estimate earlier in the
log. `scripts/run_freq_sweep.sh` gets this right and marks non-converged runs
`UNCONVERGED`; older scripts do not.

**Piping a build into `tail` hides its exit code.** Check for artifacts.

---

## Rebuilding, if resumed

Environment this depended on, none of it in this repo:

- nextpnr-xilinx with `nextpnr-patches/` applied (was
  `/home/colin/src/nextpnr-xilinx-heatmap`)
- prjxray-db, and a chipdb at `openxc7/chipdb/xc7k325tffg676-1.bin` (~441 MB,
  regenerate rather than archive)
- yosys (was `/home/colin/src/yosys-upstream`); synthesis peaks at **~10 GB
  RSS**, which on this 13.9 GB host will starve anything else — including, on
  2026-09-05, a concurrent Vivado run that died mid-route

`FREQ` has no safe default in `build.sh` and is the timing constraint for
every domain — the XDC `create_clock` does not reach `bus_clk`/`clk_h`.
Setting it wrong signs the design off at the wrong frequency, silently.

## Still worth doing, independently of the flow

`docs/upstream-issue-*.md` and `docs/nextpnr-xilinx-control-set-bug.md`
document real nextpnr-xilinx defects found here, including
`--placer-heap-beta` being silently discarded on the xilinx arch. Those are
worth filing upstream whether or not AM01 ever uses this flow again.

## Deliberately NOT copied here — these stay live

Referenced by the mux work above but owned by the Vivado flow, which is
continuing. Copying them would create a second copy that silently drifts:

- `../tools/mux2_transform.py` — the S-box pair-sharing transform itself, and
  `../tools/mux2_pipelined_transform.py`
- `../hdl/mux4/` — `encrypt_mux2.v`, `miner_mux4.v`, the mux4 wrapper and top
- `../hdl/sbox_large_mux2.v`
- `../vivado/build_mux4.tcl` — the 4-instance experiment, and the only place
  the muxed clk_2x path can actually be timed
- `../hdl/clk_gen_hash.v` — the MMCM; untouched by this archive

Note `mux2_transform.py` had a real bug fixed on 2026-09-05 (commit efbef24):
it assumed a 1-clk_h S-box, but the shipping core is `--bram-out-reg` whose
S-box is 2 clk_h, so the transformed core synthesised, fitted, and computed
**permanently-X garbage**. It now measures the latency out of the RTL. Any
mux material predating that commit is suspect.
