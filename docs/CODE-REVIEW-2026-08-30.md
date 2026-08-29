# Code review findings — 2026-08-30

Findings from a review of the uncommitted working-tree diff (`odo_gen.cpp`,
`encrypt.v`, `odocrypt_gpio_wrapper.v`, `floorplan_stripe.py`,
`tb_sched_equiv.v`). Recorded so none of them is lost; **none is fixed yet.**

`git diff master...HEAD` is the whole 218-commit branch (308k lines, mostly
generated STLs and PDFs) and is not reviewable as a unit, which is why the
working tree was the scope.

---

## Blocking

### 1. `encrypt.v` has the pre-fix round-key tap — wrong hashes

`hdl/odocrypt/encrypt.v:15429`

The regenerated RTL still taps `period[3*i]` (`period[0], [3], … [60]`) with
`state[20:0]`, `period[62:0]`, `progress[252]`. That solves to `extra_delay=0`
and the old `RoundCycles()*i` formula. The fixed generator emits
`period[1], [4], … [61]`, `state[22:0]`, `period[64:0]`, `progress[258]`.

mtimes confirm it: `encrypt.v` is 08-28, `odo_gen.cpp` is 08-29. The generator
was fixed; the RTL was never regenerated from it.

This is exactly the failure the `odo_gen.cpp` comment describes — the round key
arrives one cycle early, hashes are wrong, and the pool silently rejects every
share. **Regenerate before any build off this branch.**

The `RoundKeyTap` change in `odo_gen.cpp` itself is correct. It was re-derived
independently as `T = RoundCycles*(i+1) − 2`, confirmed identity-preserving for
the non-outreg case (`2i`), and the maximum tap stays inside `period[]`.

### 2. Regeneration command omits `--bram-out-reg`

`tools/odo_gen/odo_gen.cpp:200`, duplicated at `tools/check-epoch.sh:58`

The command stamped into `encrypt.v` leaves out `--bram-out-reg`, and nothing
records which mode produced the file. Following it at the next epoch rollover
silently reverts to a 2-cycle-per-round core.

This is the mechanism by which finding #1 recurs, so fixing #1 without fixing
this only buys one epoch.

---

## Touch / display RTL — introduced 2026-08-29 in the v1.4 work

These are defects in the XPT2046 and `LCD_DATA8` code added yesterday. **The
0x0104 bitstream that was built and flashed contains all of them**, so its
touch support should be treated as non-functional until they are fixed.

### 3. `lcd_start` re-arms and retransmits each byte 2–10 times

`hdl/odocrypt_gpio_wrapper.v:511`

`lcd_start` is only cleared in `S_IDLE`, which is not reached until the CM4
releases `WR_N` — a libgpiod ioctl, so microseconds. The SPI transfer takes
1.28–2.56 µs, so the shifter finishes, sees `lcd_start` still high, and sends
the same byte again 2–10 times.

This is the same surplus-byte class of defect that `LCD_DATA8` was added to
avoid, and `LCD_DATA8` inherits it.

### 4. Touch exchange silently dropped by LCD priority

`hdl/odocrypt_gpio_wrapper.v:593`

`T_READ_X` arms the Y read with no `!lcd_start` guard, and even `T_IDLE`'s
guard loses to a `lcd_start` asserted in the same cycle. When that happens the
FSM latches a stale `spi_rx[14:3]` and reports it as a coordinate. A dropped
read should be abandoned, not turned into a plausible-looking wrong number.

### 5. MOSI changes on the SCLK rising edge — zero setup time

`hdl/odocrypt_gpio_wrapper.v:540`

`spi_mosi` and `spi_sclk` are assigned at the same clock edge, so MOSI moves
coincident with the rising edge the slave samples on. The adjacent comment
claims the opposite. This was tolerable when only the panel was being written
to; it is now load-bearing for the XPT2046 command byte.

### 6. Touch clocked 3x over spec

`hdl/odocrypt_gpio_wrapper.v:522`

The touch path reuses the panel's fixed `bus_clk/8` divider. At a 50 MHz
`bus_clk` that is 6.25 MHz; the XPT2046's DCLK maximum is 2.0 MHz.

### 7. No synchroniser on `touch_irq`

`hdl/odocrypt_gpio_wrapper.v:565`

`touch_pressed <= ~touch_irq` samples an asynchronous pad directly. That was
survivable when it only fed a status register; it now gates an FSM.

### 8. `touch_tick` comment states the wrong clock

`hdl/odocrypt_gpio_wrapper.v:609`

The comment says "~10ms at 100MHz". `bus_clk` is 50 MHz, so the interval is
20 ms. The same incorrect 100 MHz assumption is what made the 6.25 MHz touch
DCLK in #6 look acceptable when it was written.

---

## Floorplanning and test

### 9. `--cols-per-round` narrowing branch runs by default and permutes BELs

`hardware/qmtech-kintex7/openxc7/floorplan_stripe.py:173`

The comment says the narrowing branch is a no-op by default, but the default
`--cols-per-round=3` is less than 7 columns, so it runs on every default
invocation. It cannot narrow anything — the chunk is fully consumed — so its
only effect is to permute member-to-BEL assignment, destroying the
sbox-index-to-Y ordering the Y-band scheme exists to create.

### 10. `tb_sched_equiv` can never report FAIL in the mode that is cited

`hdl/tb_sched_equiv.v:150`

`+blocks=1` — the mode `odo_gen.cpp` names as the detector for #1 — gives
k=1 < `MIN_SEQ=8`, so `RESULT` is always `INCONCLUSIVE` and
`run_sched_equiv.sh` can never emit FAIL. The named detector cannot detect.

### 11. `--no-rotate` is accepted and ignored

`hardware/qmtech-kintex7/openxc7/floorplan_stripe.py:86`

Parsed, never read. A silent no-op.

---

## Suggested order

1. **#1 and #2 together** — regenerate `encrypt.v`, and fix the stamped command
   so it cannot silently revert. Everything else is cosmetic next to wrong
   hashes.
2. **#10** — the detector for #1 must be able to fail before it is trusted.
3. **#3 through #8** — the touch and display RTL, as one bitstream rebuild.
   #3 and #4 are correctness; #5, #6 and #7 are marginal-timing issues that
   will present as intermittent.
4. **#9 and #11** — floorplanner.
