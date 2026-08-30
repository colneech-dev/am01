# Plan: adopt the Cyclone V miner core

Replacing `hdl/odocrypt/miner.v` (the AtomMiner original) with
`odo-miner-cyclonev/hdl/src/pipelined/odo_miner_core.v` (a rewrite that
demonstrably produces accepted shares).

Written 2026-08-30, after a day in which three separate faults in the AtomMiner
core and its wrapper each independently prevented this board from earning
anything.

---

## Will it improve the hashrate? No.

Worth settling first, because it determines whether this is worth doing at all.

Hashrate is `clock x instances / clocks-per-hash`. The swap changes none of the
three:

| Term | Now | After | Why |
|---|---|---|---|
| clocks-per-hash | 4 | 4 | both cores wrap the same `odo_keccak` at `THROUGHPUT=4` |
| instances | 2 | 2 | BRAM-bound: 840 of 890 RAMB18. `encrypt.v` and the S-boxes are untouched |
| clock | 133.33 MHz | ~133.33 MHz | the critical path is inside `encrypt.v`, not the nonce counters |

The new core is slightly *less* logic (no `start_hash` gating, no
`cou_deltanonce`, no `host_break`), so Fmax may improve marginally, but nothing
that changes the headline figure.

The only throughput it recovers is the halt-on-find settle window, MEASURED at
**0.05%**: ~15 finds/sec at difficulty 0.001 and 66.7 MH/s, each costing one
4096-cycle settle (30.8us at 133.33MHz) = 476us per second.

**The real hashrate win is unrelated to this plan.** `CLKFBOUT_MULT 16 -> 19` in
`clk_gen_hash.v` takes clk_h to 158.33 MHz and the hashrate to **79.2 MH/s**,
+19%, for a one-line change. It applies to either core. Do that separately, and
mind the thermals -- 53-59 C idle already.

**So do this for correctness and maintainability, not speed.**

---

## Why do it at all

Three of the faults found on 2026-08-30 **cannot exist** in the Cyclone V core:

1. **nonce_out desync.** Ours gated the nonce counter on `nonce_out_go`, so
   results arriving before the warm-up went uncounted and the counter lost sync
   with the result stream permanently. Theirs has no gate: `nonce_in` and
   `nonce_out` free-run from reset, so the Nth result pairs with the Nth input
   by construction.
2. **Too-narrow warm-up counter.** Ours was `reg [5:0]` against a pipeline
   needing far more; theirs uses a 13-bit settle counter in the wrapper.
3. **Alternate-dispatch arming.** Ours arms on a target-word count; theirs has
   no arming at all -- it runs continuously.

It also has a purpose-built one-cycle `found` strobe with a written rationale
about not losing finds, feeding a FIFO. Ours has a single nonce latch, so
simultaneous hits from the two instances lose one.

The AtomMiner lineage is the root of all three. This wrapper's own comments say
constants are "kept byte-for-byte identical to the reference rather than
re-derived" -- which is exactly how figures sized for a shallower pipeline came
across intact.

---

## Prerequisites -- do not start before these

**P1. 0x0108 built, flashed, and shares actually flowing.**
Without a working baseline there is no way to tell whether the new core helped,
did nothing, or broke something. This is the single most important gate.

**P2. Past the epoch rollover (2026-09-04 00:00 UTC).**
That rebuild is compulsory and already carries three RTL fixes. Do not stack a
core swap on top of a deadline.

**P3. On a branch, with the 0x0108 bitstream preserved.**
`vivado/artifacts/` already holds the pattern. A known-good `.bit` to fall back
to is what makes this reversible.

---

## Phase 1 -- bring the core in (half a day)

Copy, do not reference across repos. Same reasoning as `miner_pipe_am01.c`:
odo-miner-cyclonev is a separate project with different hardware under it.

    hdl/odocrypt/odo_miner_core_am01.v

**Name collision.** Their file declares `module miner(clk, header, target,
nonce, found)` and ours declares `module miner(clk, header, target, start_hash,
res, nonce)`. Both cannot be elaborated together. Rename the incoming one --
`miner_pipelined` -- rather than deleting ours, so an A/B is possible.

Carry a divergence banner listing every local change, as `miner_pipe_am01.c`
does.

**Check `THROUGHPUT`.** Their core reads a `\`THROUGHPUT` macro. Confirm it
resolves to 4 in this tree and is not being picked up from a different define.

---

## Phase 2 -- wrapper rework (the real work, 1-2 days)

`hardware/qmtech-kintex7/hdl/odocrypt_gpio_wrapper.v`.

**Remove:**
- `start_hash_h` and the whole arming path (`target_word_cnt_h`, the 8th-word
  trigger)
- `host_break_sm` and `host_break_debounced`
- `ticket2moon_i`, `cou_deltanonce_top`, `nonce_out_go_top`, `SETTLE_CYCLES`
  in its current form
- `OP_HOST_BREAK` handling, if nothing else uses it

**Add:**
- **Registered header/target with a commit toggle.** Their wrapper snapshots
  `header_flat`/`target_flat` into the hash domain on a commit edge. Ours
  currently feeds `odo_block_data`'s output straight in. Either keep
  `odo_block_data` as the shift register and add the snapshot, or replace it
  with addressed registers. The snapshot is what makes the CDC data-stable.
- **Settle counter, 13-bit, 4096.** Copy theirs. It is already in our wrapper as
  `SETTLE_CYCLES`; it moves to gate `new_find` instead of `ticket2moon_i`.
- **A found FIFO.** This is the piece we do not have. Theirs pushes every
  `found` strobe into a FIFO; ours has one latch plus an IRQ. Minimum viable: a
  small (8-deep) FIFO with an overflow counter exposed in `STATUS`, so a lost
  find is *visible* rather than silent.
- **A new bus register** for FIFO depth/overflow, so the host can see whether
  finds are being dropped.

**Keep:**
- the entire GPIO bus state machine -- untouched by this
- `NONCE_BASE` per instance. Their core spells it `parameter INONCE`; the
  two-instance split at 0 and 0x80000000 carries over unchanged.
- the XADC, fan and display paths -- unrelated

---

## Phase 3 -- verification BEFORE any hardware

This is where the value is. Today's faults all survived because nothing
compared behaviour against a software oracle.

**V1. Extend `tb_encrypt_oracle` to the whole core.**
It currently proves `encrypt.v` bit-exact. Write `tb_miner_oracle`: drive the
new core with a fixed header and a loose target, capture `(nonce, found)`, and
check with the same oracle `am01_smoke` uses that the reported nonce really
satisfies the target. **This is the test that would have caught the nonce_out
desync on day one.**

**V2. Negative control.** Deliberately break the settle window (set it to 0) and
confirm V1 FAILS. A test that cannot fail proves nothing -- `tb_sched_equiv`
already taught this lesson here.

**V3. Nonce alignment sweep.** Feed N known blocks, assert the Nth `found`
carries exactly the Nth nonce. That is the invariant the whole design rests on,
and it should be asserted directly rather than inferred.

**V4. FIFO overflow.** Force simultaneous finds on both instances; confirm the
overflow counter increments and no find is silently lost.

---

## Phase 4 -- timing and placement re-validation (1 day, mostly waiting)

A different core is a different netlist, so **all current placement and timing
results are void**: the 155-166 MHz openxc7 figures and 5/5 seed pass rate were
measured against the AtomMiner netlist.

- re-run the openxc7 seed sweep
- re-check Vivado timing closure at 133.33 MHz, then at 158.33 if the MMCM
  change is taken at the same time
- re-measure BRAM: must stay at 2 instances

Do not assume it fits or closes because the old one did.

---

## Phase 5 -- host software (half a day)

`hardware/qmtech-kintex7/sw/miner_pipe_am01.c`:

- **remove the re-arm after every find** -- the core no longer halts
- **remove `discard_first`** -- already version-gated, so it self-retires, but
  delete the dead path
- **keep `disp` job tracking**, and reconsider it. With a continuously running
  core and a FIFO, a drained nonce may belong to an *older* job than `disp`.
  Either tag FIFO entries with a job sequence number, or rely on the settle
  window and accept that a job change invalidates in-flight finds.
- **remove the double-arm** in `am01_bus_submit_work()` once no pre-0x0106
  bitstream is in service

---

## Risks

| Risk | Mitigation |
|---|---|
| Wrapper rework introduces new faults | Phase 3 oracle tests before any flash; keep the old core for A/B |
| Timing does not close | Phase 4 before committing; 0x0108 `.bit` preserved |
| Does not fit in BRAM at 2 instances | measure early in Phase 4; the swap should not change BRAM |
| FIFO is new, unproven RTL | V4, plus an overflow counter so failures are visible not silent |
| Scope creep into the MMCM change | do the clock separately, so a hashrate change and a core change are never in the same bitstream |

---

## Effort

Roughly **3-4 days** of focused work, most of it Phase 2 and Phase 3, plus
waiting on builds. Not a swap; a rework.

## Recommendation

Do it, but **after** 0x0108 is confirmed earning and the epoch has rolled. The
three fixes already made converge the AtomMiner core onto the same invariant the
Cyclone V core has by construction, so the urgent correctness problem is
addressed either way. This plan buys a simpler design with fewer traps, not a
faster one -- and the honest reason to do it is that the AtomMiner lineage has
now produced three separate silent-wrong-answer bugs in a single day.
