# TODO

Open items, newest first. Things that are *done* live in git history and in
`docs/CODE-REVIEW-2026-08-30.md`; this file is only what is still outstanding.

---

## 1. The wrapper edit is PARSE-checked, not ELABORATED

`hardware/qmtech-kintex7/hdl/odocrypt_gpio_wrapper.v`

The `target_word_cnt_h` narrowing (4 bits -> 3) and the `VERSION` bump to
`0x0106` were checked with:

    iverilog -Wimplicit -g2005 -o /tmp/wrapcheck \
        -y hdl/odocrypt -y hardware/qmtech-kintex7/hdl \
        hardware/qmtech-kintex7/hdl/odocrypt_gpio_wrapper.v

That run reported **6 errors during elaboration**:

    Unknown module type: XADC
    Unknown module type: odo_block_data
    Unknown module type: host_break_sm
    Unknown module type: miner_top   (x2)

Those are missing module definitions, not faults in the edit — `XADC` is a
Xilinx library primitive with no iverilog model, and the other three live
inside multi-module files (`hdl/odocrypt/atomminer_misc.v`, `miner.v`) that
`-y` cannot resolve, since `-y` expects one module per file named after the
module.

**So the file was proven to PARSE and nothing more.** Width mismatches,
truncation warnings and connectivity problems all surface at elaboration, and
elaboration never completed. A three-bit change to a counter that is compared
against a four-bit literal is exactly the kind of edit an elaboration pass
would have something to say about.

Before trusting it, do one of:

* elaborate with the real sources listed explicitly rather than via `-y`, and
  a stub for `XADC`; or
* let Vivado synthesis be the check — it parses the RTL properly and will
  report width mismatches. This is the natural option because a bitstream
  rebuild is needed anyway (item 2).

Do NOT treat "iverilog printed no syntax error" as verification. That is the
same shape of mistake as the earlier `lcd_start` synthesis failure, where an
iverilog run that filtered warnings hid the one diagnostic that mattered.

---

## 2. Bitstream rebuild for VERSION 0x0107

Two RTL fixes are now waiting on one rebuild, and NEITHER is in any bitstream in
service. The board runs 0x0105.

**0x0106 -- `target_word_cnt_h` 4 bits -> 3.** Armed the core on every other
dispatch. Covered meanwhile by the version-gated double-arm in
`am01_bus_submit_work()`.

**0x0107 -- settle window 205 -> 4096 cycles.** This is the one that stops
shares. The 205 came from mirroring the AtomMiner reference; the Cyclone V
build, running the SAME miner.v, uses 4096 and documents exactly why -- stale
old-header results drain through the pipeline and spuriously qualify against
the new target. At 205 the window closed while they were still draining, so the
first find after every arm was a previous-header result wearing a new nonce.

**There is no software workaround for 0x0107.** A misreported nonce cannot be
recovered host-side; this one needs the silicon. Measured with the workarounds
for everything else in place: `found=35440 shares=0 stale=35440` over ~100 s.

## 2b. Old note, kept for context: rebuild for VERSION 0x0106

The every-other-dispatch arming bug is FIXED IN RTL but **not in any bitstream
in service**. The board is running `0x0105`, which still has it.

Until `0x0106` is built and flashed, correctness depends on the software
workaround in `am01_bus_submit_work()`, which sends the target block twice when
it reads a version at or below `0x0105`. That is measured to work — 6 valid
nonces out of 6 against a 1-in-256 target — but it is a workaround.

The version gate means no coordination is needed: flashing `0x0106` makes the
workaround stop firing on its own, because the check is `ver <= 0x0105`.

Rebuild is ~1h35m. **Combine it with the epoch rollover (item 3)** — that
rebuild is compulsory anyway, so doing both at once costs nothing extra.

---

## 3. Epoch rollover — 2026-09-04 00:00 UTC

After that the core mines rejects regardless of everything else.
`tools/check-epoch.sh` now prints the correct regeneration command including
the `--bram-out-reg` flag state, so follow what it says rather than the
command in this file or in anyone's memory.

---

## 4. Remove the double-arm workaround

Once no `0x0105`-or-earlier bitstream is in service anywhere, delete the
`AM01_LAST_ALT_ARM_VERSION` path in `am01_gpio_bus.c`. Leaving it costs ~160us
per job change and nothing in steady state, so this is tidiness, not urgency.

---

## 5. Fan tach reads 0

The FPGA side is proven end to end: forcing `fan_floor` to 255 gives duty
255/255 at the pin across ten samples, and the auto curve tracks real XADC
temperature (53.4C -> 102, 56.6C -> 140, both correct for their band). The tach
input reads exactly 0 in every sample — electrically quiet, so the line is held
rather than floating and noisy.

Unresolved on the hardware side: whether the fan's tach wire reaches JP5 pin 44
at all, and whether a 12V fan on this board's 5V rail produces a tach signal.
`am01_probe fan 255` plus a meter on pin 44 settles it (expect ~1.5-1.7V while
spinning if the tach is pulsing).

---

## 6. Display

The `CASET`/`PASET` corruption is fixed (`ADDR_LCD_DATA8` is now bound and
used). Not yet confirmed working on hardware, because the panel turned out to
be a **5 V** module and was disconnected before a successful run.

Before reconnecting, see the 5 V warning in `docs/JP5-WIRING.md`: bank 12 is not
5 V tolerant, so `T_DO` must be metered before it goes anywhere near JP5 pin 5.
