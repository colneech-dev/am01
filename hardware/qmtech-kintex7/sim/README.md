# Simulation / regression tests

Behavioural tests for the RTL in `../hdl/`, runnable with iverilog — no
licensed simulator needed.

```sh
ODO=../../../exmaples/odocrypt/fpga/src/hdl
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
