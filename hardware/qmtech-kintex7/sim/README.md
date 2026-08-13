# Simulation / regression tests

Behavioural tests for the RTL in `../hdl/`, runnable with iverilog — no
licensed simulator needed.

```sh
ODO=../../../hdl/odocrypt
iverilog -g2005 -DTHROUGHPUT=4 -o /tmp/tb tb_nonce_split.v \
    $ODO/miner.v $ODO/encrypt.v $ODO/keccak800.v
vvp /tmp/tb
```

**These are slow.** The full OdoCrypt/keccak core simulates at roughly
**2 seconds per simulated clock cycle** here, so anything that has to
reach the core's 205-cycle warm-up takes 5-10 minutes. Tests are written
to probe the earliest cycle that proves the point rather than running to
completion.

## `tb_nonce_split.v`

Guards the multi-instance change (`NUM_MINERS` in
`../hdl/odocrypt_gpio_wrapper.v`, `NONCE_BASE` in `miner`/`miner_top`).

Two `miner_top` instances are built with `NONCE_BASE` 0x00000000 and
0x80000000, and their internal nonce counters are probed directly. It
asserts the counters start at their respective bases and stay exactly
0x80000000 apart while hashing.

**Why this matters:** if `NONCE_BASE` failed to plumb through, both
cores would sweep *identical* nonces. The design would still synthesise,
still fit, and still look like "2 instances" in a utilisation report —
while delivering **zero** extra hashrate for double the power. Resource
counts cannot catch that; only this check can.

Measured output:

```
=== at reset (start_hash low) ===
  A.nonce_in = 00000000   (expect 00000000)
  B.nonce_in = 80000000   (expect 80000000)
=== after 40 cycles of hashing ===
  A.nonce_in = 00000009
  B.nonce_in = 80000009
  separation = 80000000
```

Both advance in lockstep, half the nonce space apart — no duplicated
work.

> Note for anyone extending these: do not write
> `$display(cond ? "PASS..." : "FAIL...")`. Verilog treats the two string
> literals as numeric vectors of differing width and prints garbage
> instead of either string. Use an `if`/`else` with separate `$display`
> calls. (Learned the hard way — the first version of this test printed a
> 150-digit number as its verdict.)

## `tb_encrypt_equiv.v` — shared-BRAM encrypt core equivalence

Proves that the core produced by `../tools/mux2_transform.py` (pairs of
large S-boxes sharing one block RAM via a 2x clock) is bit-identical to
the stock OdoCrypt core. Run it with `run_encrypt_equiv.sh`, and re-run
it every 10-day epoch, since `encrypt.v` is regenerated and the transform
has to be re-applied and re-proved.

**Measured result:**

| run | mode | defined cycles | data mismatches | verdict |
|---|---|---|---|---|
| `+pinv=0` | intended interleave | 493 | 0 | **PASS** |
| `+pinv=1` | phase inverted | 493 | 0 | PASS (expected) |
| `+pstuck=1` | phase held constant | — | 100% of compared | **FAIL** (required) |

The third row is the one that gives the first row its weight. A test that
cannot fail proves nothing, so `+pstuck=1` holds `phase` constant, which
starves S-box slot 1 and is genuinely broken hardware. It mismatches from
the very first defined cycle. Only because that fails can the clean run's
zero mismatches be believed.

`+pinv=1` is **not** a control, though an earlier version of this test
claimed it was and required it to fail. Inverting the interleave phase is
a benign relabelling: both slots are still serviced exactly once per
`clk_h`, and only the sub-`clk_h` moment at which each slot's output
register updates changes. Both orderings settle before the `clk_h` edge
downstream logic samples on. It passes, as it should, and enforcing the
original criterion would have condemned a valid result.

### Two traps this test is built around

**Comparing X against X.** The stock and muxed cores are elaborated in
one simulation on shared stimulus, and only cycles where the *reference*
output is fully defined are counted; below a floor of 100 such cycles it
reports `INCONCLUSIVE` rather than `PASS`. This is not hypothetical — an
earlier version was two processes diffing two files, and when a container
restart killed both mid-run, each file held nothing but an unflushed
buffer of all-X. A plain `diff` would have called that a match.

**Runtime is not linear.** Cost per simulated cycle jumps by an order of
magnitude once the pipeline fills, because while everything is X the
signals are *static* and an event-driven simulator has nothing to do.
Timing a short probe measures only that cheap phase: a 40-cycle probe
suggested 2.7 s/cycle and 27 minutes total, and the real runs took over
70 minutes of CPU each. Budget hours, and watch the progress line.

> Incidental finding: `out` becomes fully defined at **cycle 44**, not at
> cycle 172. The 172 figure is the depth of the `write` valid strobe
> (`assign write = progress[171]`), which is not the same as the depth at
> which the output bus stops carrying X.
