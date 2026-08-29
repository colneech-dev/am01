# Code review — 2026-08-30

Scope: branch commit `fbd6433` (odo_gen round-key tap fix, testbench changes,
`run_e2nb_fixed.sh`) plus the uncommitted working-tree changes to
`encrypt.v`, `odocrypt_gpio_wrapper.v` and `floorplan_stripe.py` — which is
where most of the risk turned out to sit.

The generator fix itself was checked and holds: `RoundKeyTap(i) =
RoundCycles()*(i+1)-2` yields `2*i` for the reference (byte-identical to
before) and `3*i+1` with `--bram-out-reg`, matching the pipeline derivation
(a tap read at X yields a key at X+1; the sbox output emerges at
`RoundCycles*i + sbox_latency`). The `period[]` array remains deep enough for
the larger maximum tap.

Status key: **FIXED** · **OPEN — not mine** (belongs to the author of that
work) · **DEFERRED** (mine, blocked on a running job).

---

## 1. `hdl/odocrypt/encrypt.v` — shipped core computed wrong digests · FIXED

The working-tree file carried the second sbox register (`q1`, all 40 small and
10 large sboxes) but kept the taps at `period[3*i]` — `get_key0`→`period[0]`,
`get_key1`→`period[3]` … `get_key20`→`period[60]`. That is exactly the pre-fix
formula that `fbd6433` corrects, so **every round key arrived one cycle early
and the core produced wrong digests** — surfacing as silent pool rejects, not
as a failure.

This is the file the normal build path uses. The timing experiments never hit
it because they pass `gen/encrypt_*.v` copies explicitly, which is why it went
unnoticed.

**Cause:** left behind when `encrypt.v` was regenerated with `--bram-out-reg`
during the timing work, using the then-broken generator.

**Fix:** restored from HEAD (which was clean: `period[0,2,4]`, `state[21:0]`,
no `q1`) and verified **byte-identical to current generator output**. That
also re-confirms the `extra_delay` and key-tap fixes leave the reference core
untouched.

## 2. `hdl/odocrypt/encrypt.v` — matched no generator output · FIXED with #1

The same file had `extra_delay=0` (`state[20:0]`, `period[62:0]`,
`progress[252:0]`) where the current generator yields `extra_delay=2`
(`state[22:0]`, `period[64:0]`, `progress[258:0]`). The recirculation relay was
absent, and the file's own header documented a regeneration command *without*
`--bram-out-reg` — so it contradicted itself, which is the tell.

## 3. `odocrypt_gpio_wrapper.v:571` — touch request dropped, stale coordinates latched · OPEN — not mine

```verilog
if (touch_start && spi_busy) touch_start <= 0;
```

clears a pending touch request when the **LCD** wins arbitration. The FSM then
advances anyway and latches stale `spi_rx[14:3]` into `touch_x`/`touch_y`, so
the host reads coordinates from a transfer that never happened.

## 4. `odocrypt_gpio_wrapper.v:522` — LCD write protocol is racy · OPEN — not mine

Now that touch can claim the shifter asynchronously, the documented
"poll `LCD_STAT`, then write" protocol no longer holds: `LCD_CMD`, `LCD_DATA`
and `LCD_DATA8` **drop the write while still acking it**. A dropped command
byte desynchronises the ILI9341 command stream, which does not self-recover.

## 5. `floorplan_stripe.py:173` — `--cols-per-round` is a no-op · OPEN — not mine

`keep + spill` is a same-length permutation of `chunk`, and `zip()` consumes
all of it, so the per-round column set is unchanged whatever the flag says. The
dead branch runs on **every default invocation** (default 3 < 7 columns), so
any result attributed to this knob is attributable to something else.

## 6. `floorplan_stripe.py:86` — `--no-rotate` parsed but never read · OPEN — not mine

Dead option; the docstring's ROTATION section is stale after the rewrite.

## 7. `sim/tb_sched_equiv.v` — `+blocks=1` could never report FAIL · FIXED

The verdict tested `k < MIN_SEQ` **before** `mismatches != 0`, so a single
compared result printed `INCONCLUSIVE` even when it mismatched. `+blocks=1` is
the mode credited with catching the round-key bug, and it worked only because
the separate `MISMATCH` line prints — the verdict itself read identically
before and after the fix.

**Fix:** a detected mismatch is now a FAIL at any sample size; insufficient
samples only withholds a PASS.

## 8. `run_e2nb_fixed.sh:53` — key-tap "check" is a print, not a check · DEFERRED

It echoes the taps and an expected value for a human to compare. `odo_gen`'s
exit status is unchecked, and the (gitignored) binary is never rebuilt — so a
stale or failed generator silently feeds a ~2 h synthesis plus five routing
runs. Should assert the taps and fail hard.

## 9. `run_e2nb_fixed.sh:56` — stale netlist can be routed · DEFERRED

Synthesis is skipped on mere existence of `$OUT/am01_qmtech_top.fp.json`, so a
stale netlist gets routed while freshly regenerated Verilog is ignored. Should
compare against the source, or force regeneration.

*8 and 9 are deferred only because the script was executing when the review
landed; editing a running bash script corrupts it (it re-reads by byte offset),
which has already cost time once in this work.*

---

## The pattern worth noting

Findings 1, 2 and 7 are the same failure: **an artefact that looks right and is
checked by eye rather than by assertion.** The broken `encrypt.v` looked like a
generated file; the `+blocks=1` verdict looked like a verdict; the tap check in
finding 8 looks like a check. In each case the thing that would have caught it
was a comparison the machine performs, not one a human performs while reading
output.
