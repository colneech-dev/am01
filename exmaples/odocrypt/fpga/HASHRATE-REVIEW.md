# OdoCrypt on AM01 — code review, with focus on hash rate

Independent review of `fpga/src/hdl` (`atomminer_odocrypt.v`, `miner.v`, `keccak800.v`,
`encrypt.v`, `usb3_interface.v`, `usb3_sm_v3.v`, `atomminer_misc.v`), the constraints,
and `fpga/utilization.txt`.

Claims about pipeline behaviour below were checked by RTL simulation
(`src/sim/miner_latency_tb.v`, Icarus Verilog), not by inspection alone. Claims about
timing closure were **not** — there is no timing report in the repo and no Vivado in the
review environment. Those are marked as such.

---

## 1. Where the hash rate currently comes from

```
gclk            19.2 MHz
MMCM            × 46.875 / 1, VCO = 900 MHz          (artix200_v3_clocking.xci)
CLKOUT0_DIVIDE  18.0
clk_h           50.0 MHz
THROUGHPUT      4 clocks per hash                    (miner.v:18)

hash rate = 50.0 MHz / 4 = 12.5 MH/s
```

The pipeline is *correctly* dimensioned — this is worth stating plainly, because it is the
first thing a reader assumes is wasteful and it is not:

| block | rounds | unrolled | passes | loop length | latency |
|---|---|---|---|---|---|
| `encrypt_4encrypt_loop` | 84 | 21 | 4 | 43 cyc | 172 cyc |
| `keccak_hasher` | 12 | 3 | 4 | 7 cyc | 28 cyc |
| `cmp_256` | — | — | — | — | 2 cyc |

`gcd(4, 43) = 1` and `gcd(4, 7) = 1`, so with one nonce injected every 4 cycles all 43 (resp. 7)
loop slots are occupied. **Every pipeline stage is busy every cycle.** Lowering `THROUGHPUT`
would not buy anything; it would just force more unrolling for the same work per LUT.

Measured end to end (simulation): **204 clk_h cycles** from `advance` to `has_res`
(172 + 2 wrapper + 28 + 2), matching the arithmetic above.

So the only two levers on hash rate are **clock frequency** and **number of cores**.

---

## 2. Biggest finding: the unrolling factor strands 42% of the block RAM

The S-box layer is where all the BRAM goes. Per round (`encrypt_4apply_sboxes`):

- 40 × `sbox_small` — 64 × 6 ROM, 1 lookup → inferred into LUTs
- 20 × `sbox_large` — 1024 × 10 ROM, 2 lookups (true dual port) → **1 RAMB18 each**

20 RAMB18 × 21 rounds = **420 RAMB18**, exactly the `420 RAMB18E1` in `utilization.txt`.
In tiles: 210, plus 1 RAMB36 tile for the USB system RAM = 211 / 365 = 57.8%.

That is the whole problem. **A second core needs another 210 tiles and there are only 154 left.**
Meanwhile the rest of the device is idle:

| resource | used | headroom |
|---|---|---|
| Slice LUTs | 27.5% | 72.5% |
| Slice registers | 10.3% | 89.7% |
| DSPs | 0% | 100% |
| **Block RAM tiles** | **57.8%** | **42.2% — stranded** |

BRAM cost scales with the *unrolling factor*, hash rate scales with `cores × unrolling`.
With `U` rounds unrolled the design uses `10U` tiles per core and runs at `84/U` clocks per hash,
so with 364 usable tiles:

| unrolled `U` | THROUGHPUT | tiles/core | cores | tiles used | rate |
|---|---|---|---|---|---|
| **21 (current)** | 4 | 210 | **1** | 211 | **0.250 × f** |
| 14 | 6 | 140 | 2 | 281 | 0.333 × f (+33%) |
| **12** | **7** | **120** | **3** | **361** | **0.429 × f (+71%)** |
| 7 | 12 | 70 | 5 | 351 | 0.417 × f (+67%) |
| 6 | 14 | 60 | 6 | 361 | 0.429 × f (+71%) |

**21 is the worst choice on the list.** 364/210 = 1.73 — the second core is 73% paid for and
never built. Any of `U = 12, 6, 4, 3, 2, 1` reaches the ceiling of 36 rounds-in-flight versus
today's 21.

`U = 12` (THROUGHPUT 7, 3 cores) is the best point: it hits the maximum while instantiating the
fewest Keccak copies. It is also clean — `84/12 = 7` passes exactly, and `gcd(7, 25) = 1` for the
25-cycle loop, so no `EXTRA_DELAY` fudge is needed. Keccak at THROUGHPUT 7 gets *smaller* too
(`UNROLLING = 2` instead of 3, `gcd(7, 5) = 1`, latency 30).

Estimated cost of 3 × `U=12` cores: ~48% LUT, ~19% FF, **99% BRAM tiles** (361/365).
BRAM at 99% is legal but leaves the placer no slack, so `U=14` / 2 cores (77% BRAM, +33%) is the
safe fallback if routing gets ugly.

### How to get there

`encrypt.v` is generated — the `encrypt_4*` prefix *is* the THROUGHPUT parameter. Re-run the
[MentalCollatz/odo-miner](https://github.com/MentalCollatz/odo-miner) generator with
THROUGHPUT 7 to get `encrypt_7*` with 12 rounds unrolled, and change
`` `define THROUGHPUT `` in `miner.v` to match.

Three things must change alongside it, or the design will build and silently report wrong nonces:

1. **Split the nonce space.** `miner.v:114` starts every core at `nonce_in <= 32'h0`. Three cores
   would all hash the same nonces. Give each core an offset (`nonce_in <= {core_id, 30'h0}` or
   interleave the low bits) and apply the same offset to `nonce_out`.
2. **Recompute the latency constants** — see §4.1. They are hand-fitted to THROUGHPUT 4.
3. **Merge the result buses** — `ticket2moon` / `nonce` are single-core signals today.

---

## 3. Second finding: 50 MHz looks very conservative

I cannot prove this without running Vivado, and there is no timing report in the repo — so treat
this as "worth measuring", not as fact. But the shape of the design argues strongly for headroom:

- The critical path per pipeline stage is short. `encrypt_4apply_pbox0/1` and
  `encrypt_4apply_rotations`' bit permutations are pure rewiring (0 logic). The real path is
  *BRAM CLK→OUT → 1 LUT6 (the 6-term rotation XOR) → 1 small LUT (round key XOR) → FF*.
  Roughly two logic levels.
- 27.5% LUT occupancy and only 21 unique control sets — congestion is not the limiter either.
- `timing.xdc` contains one line (a `set_clock_groups`). There is no tightened constraint that
  would have pushed the tools to work harder, and nothing suggesting 50 MHz was arrived at by
  hitting a wall.

The MMCM makes this cheap to test: VCO is already 900 MHz (in range for a -1 part, 600–1200 MHz),
so only `CLKOUT0_DIVIDE_F` needs to change — no re-solve of M/D:

| divide | clk_h | hash rate (1 core) |
|---|---|---|
| 18.0 | 50 MHz | 12.5 MH/s (current) |
| 12.0 | 75 MHz | 18.75 MH/s |
| 9.0 | 100 MHz | 25 MH/s |
| 7.5 | 120 MHz | 30 MH/s |
| 6.0 | 150 MHz | 37.5 MH/s |

**Do this in steps and watch the telemetry.** The XADC already reports die temperature, VCCINT and
VCCAUX into status RAM at `0x20a`/`0x20b`/`0x20c`, and `test/index.js:125` already decodes
temperature and VCC. AM01 is a small USB-powered board; dynamic power scales linearly with
frequency, so the real ceiling here is likely thermal/PDN rather than timing. Raise the clock,
re-run `test/index.js`, and confirm both the nonce is still correct *and* temperature/VCCINT are
sane before going further.

Combined with §2, `3 cores × 100 MHz / 7` = **42.9 MH/s, ~3.4× the current 12.5 MH/s** — if the
power budget allows it.

---

## 4. Correctness

### 4.1 Verified correct — do not "fix" these

The nonce bookkeeping looks wrong on first read and is not. `miner.v` discards results until
`cou_deltanonce == 6'h33` (51 advances), then starts counting `nonce_out` from 0. Simulation over
943 consecutive results with an all-ones target found **0 mismatches**: `nonce_out` tracks the
nonce actually in the pipeline exactly, and `nonce_out_go` rises 2–3 cycles before the first
result — nothing is dropped and nothing is misattributed. `8'hcd` (205) at
`atomminer_odocrypt.v:219` is likewise correct.

**But the margin is 2–3 cycles and the constants are magic numbers.** `6'h33` and `8'hcd` encode
"204-cycle pipeline latency" and are silently wrong for any other THROUGHPUT — which is exactly
what §2 proposes changing. They should be derived from localparams rather than typed in.
`src/sim/miner_latency_tb.v` (added with this review) measures the latency directly, so the
constants can be re-derived after any change rather than guessed.

Also verified: the header and target load in *opposite* word orders, and both are correct.
`odo_block_data` shifts the header down (first word received ends up in `header0`, the LSB — so
the version word lands at `header[31:0]` and the nonce at `{nonce_in, header}[639:608]`, matching
block-header serialisation), and shifts the target up (first word received ends up in `target7`,
the MSB, matching a big-endian 256-bit compare — confirmed against the testbench target
`00000021 55340000 0…`, ≈ 2²²⁹, consistent with the ~2²⁶ nonces `test/index.js` expects). The
asymmetry is real and intentional; it just needs to be documented for anyone porting this to a
new algorithm, which is what this repo is for.

### 4.2 Bugs

**B1 — unsynchronised clock-domain crossing on the share report.** `usb3_interface.v:189–213`.
`go_success`/`go_unsuccess` are written in `clk_h` and sampled in `clk_100` with no synchroniser;
`strobe_data_reg` crosses the other way, also bare. Because `timing.xdc` declares the two domains
`-asynchronous`, Vivado does not time these paths *at all* — there is no error, just no guarantee.
A metastable `go_success` sample corrupts `status4_coin`/`golden_nonce`, i.e. a garbled or missed
share. Fix: 2-FF synchroniser on the control bit (the 32-bit `nonce` is already stable well before
it and can stay as a plain data bus).

**B2 — no `ASYNC_REG` on the synchronisers that do exist.** `data_from_host_rdyh_r1/r2/r3`
(`usb3_interface.v:91–93`), `FX3_ready_r/rr` (`usb3_sm_v3.v:200`), `system_host_break_r0/r1/r2`
(`atomminer_odocrypt.v:164–166`). Without the attribute the placer may spread these flops apart,
cutting the settling time available between them and lowering MTBF. One-line fix.

**B3 — non-blocking assignments in a combinational block.** `usb3_sm_v3.v:154`, the status FSM.
It also uses a hand-written sensitivity list. The list happens to be complete (I checked every
signal read in the body), and the defaults-then-case structure means it happens to behave, but
`<=` in combinational logic is a classic simulation/synthesis mismatch. Fix: `always @*` with
blocking `=`.

**B4 — `hash_cmplt` is hardwired to `1'b0`.** `atomminer_odocrypt.v:159` and `:177`. The miner
never reports nonce-space exhaustion; `nonce_in` wraps at 2³² and silently re-hashes the same
range. At 12.5 MH/s a full sweep is 343 s, so pools push new work long before it matters — but at
42.9 MH/s it is 100 s, and it becomes a real source of wasted power if the host is ever slow.
Assert it when `nonce_out` wraps.

**B5 — one-cycle window for a stale-nonce share report.**
`ticket2moon_i <= ticket2moon & nonce_out_go_top` (`atomminer_odocrypt.v:221`) is not gated by
`start_hash`, but the nonce capture at `miner.v:119` is. When `start_hash` drops,
`nonce_out_go_top` clears one cycle later, leaving a single cycle in which a result from the
draining pipeline can raise `ticket2moon_i` while `nonce` holds the *previous* share's value —
the host would submit a duplicate. Low probability; the fix is one extra AND term.

**B6 — every share drains the pipeline and restarts the nonce at 0.** `ticket2moon` →
`host_break_sm` → `start_hash <= 0` throws away the ~204 in-flight hashes, and `miner.v:114`
resets `nonce_in` to 0 for the next work item. The miner is then idle until the host sends new
work — and `test/index.js` polls at 500 ms intervals. This is architectural, not a coding error,
but a small result FIFO would let the core keep hashing while a share is reported instead of
stalling on the USB round trip.

**B7 — typo in a reset initialiser.** `atomminer_misc.v:130`:
`output reg [data_width-1:0] data_out = {data_width*1'b0}` — this is a concatenation of the
*product* `data_width * 1'b0`, not the intended replication `{data_width{1'b0}}`. Both evaluate to
zero so nothing breaks today, but it silently stops meaning "all bits zero" if anyone reuses the
module. One-character fix.

### 4.3 Constraints

`timing.xdc` is a single `set_clock_groups` line. There are **no `set_input_delay` / `set_output_delay`
constraints on the FX3 bus** (`DQ`, `strobe_data`, `we`, `FX3_ready`, `artix_ready`), so those paths
are entirely untimed. It works today because the IOB registers (`IOB="true"`) fix the flop location
and the interface is slow relative to 100 MHz — but "the design meets timing" currently says
nothing whatsoever about the host interface. Worth adding before anyone raises `clk_100`.

---

## 5. Suggested order of work

1. **Measure first.** Build the current design and read off WNS on `clk_h`. That single number
   decides how much of §3 is free. Nothing else should be done before this.
2. **Raise `CLKOUT0_DIVIDE_F` in steps** (18 → 12 → 9 → …), re-running `test/index.js` at each step
   and checking the XADC temperature/VCCINT alongside the nonce. Cheapest possible win — one IP
   parameter, no RTL change. Stop when timing or thermals say stop.
3. **Fix B1/B2/B5** before scaling anything. Multiplying the share rate multiplies the exposure to
   a racy share-report path, and these are small, local fixes.
4. **Regenerate `encrypt.v` at THROUGHPUT 7 and instantiate 3 cores** (§2). This is the structural
   +71% and the only way to use the stranded 42% of block RAM. Requires the nonce-space split, the
   recomputed latency constants, and result-bus merging — do not skip any of the three.
5. **Fallback if 99% BRAM does not route:** THROUGHPUT 6 / 14 rounds / 2 cores, 77% BRAM, +33%.
