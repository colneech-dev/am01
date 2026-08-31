# TODO

Open items, newest first. Things that are *done* live in git history and in
`docs/CODE-REVIEW-2026-08-30.md`; this file is only what is still outstanding.

---

## 0. Bitstream rebuild for VERSION 0x0109 — golden_nonce_h latched one cycle late

`hardware/qmtech-kintex7/hdl/odocrypt_gpio_wrapper.v`

Found 2026-08-31 via `am01_smoke` run directly against the (then-current)
0x0108 hardware, no pool involved: reported nonce was consistently -35 from
the nonce that actually satisfies the target. On the pool this showed as
`found=338112 shares=1 stale=338111` — virtually every genuine hit reported
the wrong nonce and was rejected as stale. This is also why miningcore showed
~700 H/s against a ~66.7 MH/s core: the pool estimator only sees the share
arrival rate, and almost nothing was surviving to become a share.

Root cause: `golden_nonce_h` (the mux picking the winning instance's nonce out
of the two `miner_top` instances) is combinational and only valid during the
single cycle the RAW `ticket2moon` (`= |t2m_arr`) is high. The latch meant to
capture it fires on `ticket2moon_rise` — the rising edge of `ticket2moon_i`, a
REGISTERED, one-cycle-delayed copy (`ticket2moon_i <= ticket2moon &
nonce_out_go_top`). By the cycle that latch fires, the raw signal has already
dropped, so the mux has fallen back to its default (`nonce_arr[0]`) — whatever
instance 0 happens to hold at that moment, not the nonce that produced the hit.

Fixed: capture the mux output into `golden_nonce_captured_h` on the RAW
`ticket2moon` edge while it is still valid; the existing gated latch now reads
from that captured register instead of the raw mux. Committed `824da3a`,
VERSION bumped to `0x0109`.

Verified by FULL iverilog elaboration (not just parse — see item 1, now
resolved): zero errors, only two benign `@*`-sensitive-to-whole-array
warnings unrelated to this change.

**Not yet verified on hardware.** Vivado rebuild was in progress at time of
writing. Once flashed: re-run `am01_smoke` (no pool, so staleness/timing
noise is ruled out) and confirm zero offset failures before trusting pool
share numbers again.

---

## 1. iverilog elaboration — RESOLVED 2026-08-31

`hardware/qmtech-kintex7/hdl/odocrypt_gpio_wrapper.v` used to only PARSE-check
under iverilog, not elaborate, because `XADC` (a Xilinx hard primitive) had no
model available. Full elaboration now works with Vivado's own bundled
Xilinx simulation library:

    iverilog -Wall -g2005 -o /tmp/check \
        -y "/c/AMDDesignTools/2026.1/Vivado/data/verilog/src/unisims" \
        hardware/qmtech-kintex7/hdl/odocrypt_gpio_wrapper.v \
        hdl/odocrypt/miner.v hdl/odocrypt/encrypt.v \
        hdl/odocrypt/atomminer_misc.v hdl/odocrypt/keccak800.v \
        "/c/AMDDesignTools/2026.1/Vivado/data/verilog/src/glbl.v"

Two libs were needed: the `unisims/` behavioral models (for `XADC` and any
other hard primitive) and `glbl.v` (provides the global `GSR`/`GTS` nets those
primitives expect). Both ship with the Vivado install already — nothing
external to fetch. This ran clean against the current wrapper (see item 0):
zero errors, only benign `@*`/whole-array-sensitivity warnings.

Use this full form for future RTL checks in this repo instead of the old
partial `-y hdl/odocrypt`-only version, which could not resolve
`odo_block_data`/`host_break_sm`/`miner_top` (they live in multi-module files
that `-y` cannot handle) or `XADC`, and so only ever proved the file PARSES —
width mismatches, truncation, and connectivity problems all surface at
elaboration, which never used to complete. Do NOT treat "iverilog printed no
syntax error" as verification; that was the same shape of mistake as the
earlier `lcd_start` synthesis failure, where a run that filtered warnings hid
the one diagnostic that mattered.

---

## 2. Bitstream rebuild for VERSION 0x0108

THREE RTL fixes now ride one rebuild. None is in any bitstream in service; the
board runs 0x0105.

**0x0108 -- `miner.v` nonce_out counts every result. THIS IS THE ONE.**
nonce_out was gated on nonce_out_go, so any result emerging before the
204-cycle warm-up went uncounted and the counter lost sync with the result
stream permanently. Every reported nonce was then wrong by however many results
had been skipped. odo-miner-cyclonev's working core has no gate on the counter
at all -- nonce_in and nonce_out free-run from reset so the Nth result pairs
with the Nth input by construction. Verified by full iverilog elaboration
(miner.v + encrypt.v + atomminer_misc.v + keccak800.v): no errors, no width
warnings.

**0x0107 -- settle window 205 -> 4096.** Stops stale old-header results being
published. Necessary but NOT sufficient on its own; it suppresses reporting and
does nothing for counter alignment.

**0x0106 -- `target_word_cnt_h` 4 bits -> 3.** Armed the core on alternate
dispatches only.

Software workarounds cover 0x0106 and (partly) 0x0107 until then, both version
-gated so flashing 0x0108 retires them automatically. There is NO workaround for
the nonce_out desync: a misreported nonce cannot be recovered host-side.

## 2b. Superseded notes: 0x0107 and 0x0106

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

## 2c. DECIDED: keep the AtomMiner core for now, revisit after the epoch

Considered 2026-08-30: replace hdl/odocrypt/miner.v with the Cyclone V's
odo_miner_core.v, which is the core that demonstrably works.

IT IS THE BETTER DESIGN. No start_hash, no host_break, no gate on the nonce
counter, a purpose-built one-cycle `found` strobe with a written rationale about
not losing finds, and a FIFO behind it. Three of the faults fixed today CANNOT
EXIST in it -- the nonce_out desync, the too-narrow warm-up counter, and the
alternate-dispatch arming are all artefacts of the AtomMiner lineage this
wrapper mirrors.

NOT DOING IT NOW, for three reasons:

  * It is a wrapper rewrite, not a file swap. This wrapper is built around the
    AtomMiner interface -- start_hash, ticket2moon, host_break_sm,
    odo_block_data shifting words in, one nonce latch plus IRQ. The Cyclone V
    core needs registered header/target, a settle window and a FIFO. All new,
    all unvalidated.
  * It discards the timing work. Placement and timing have been tuned against
    this netlist (155-166 MHz, 5/5 seeds). A different core is a different
    netlist.
  * The epoch deadline is under three days away. A big-bang core swap plus a
    wrapper rewrite plus re-validation is the wrong shape of change against a
    hard date.

The three fixes made today converge the AtomMiner core onto the same invariant
the Cyclone V core has by construction, which is the cheap way to the same
correctness.

ONE ARGUMENT THAT DOES NOT HOLD, recorded so it is not re-litigated: halt-on-
find is not a throughput problem. At difficulty 0.001 and ~66 MH/s that is ~15
finds/sec, each costing one 4096-cycle settle (30.8us) -- 0.05% overhead. It
would only bite near 32k finds/sec. An earlier commit message of mine called it
a "throughput ceiling"; that was wrong.

The real residue is the SINGLE NONCE LATCH with no FIFO: if both miner
instances hit on the same cycle, one find is lost. Rare at 15 finds/sec, and
already documented in the wrapper.

Revisit once shares are flowing and the epoch pressure is off.

A full staged plan now exists: `docs/PLAN-adopt-cyclonev-core.md`. Headline
finding from writing it -- the swap does NOT improve hashrate. Same
THROUGHPUT=4, same BRAM-bound 2 instances, same critical path in encrypt.v.
It buys a simpler design with fewer traps. The +19% is the MMCM change
(CLKFBOUT_MULT 16 -> 19, 66.7 -> 79.2 MH/s), which applies to either core
and should be done separately so a clock change and a core change are never
in the same bitstream.

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
