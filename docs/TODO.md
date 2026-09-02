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

**IN SERVICE (current epoch) + BUILT AND WAITING (rollover).** Two bitstreams
now, both VERSION 0x0203 and identical apart from the sbox.

    FLASHED 2026-09-02 00:45, running now, survives a power cycle:
      artifacts/am01_VER0x0203_158MHz_epoch1787616000_FLASHABLE-NOW.bit
      md5 283120269ff71660691ee4319b616d7c

    FOR THE ROLLOVER -- do not flash before 2026-09-04 00:00 UTC:
      artifacts/am01_VER0x0203fix_158MHz_epoch1788480000_DO-NOT-FLASH-BEFORE-2026-09-04.bit
      md5 3b9ee9e2a74e4af95f7a623937b032cd

Built at the current epoch FIRST, deliberately, so the speed change could be
flashed and MEASURED rather than taken on trust until Thursday. Two builds
instead of one, and worth it: a clock bump that cannot be verified until the
deadline is a clock bump nobody should rely on.

MEASURED, 85 minutes of uptime (this estimator is statistical -- work_acc over
uptime -- so short samples swing wildly and a few read above the design's
theoretical ceiling):

    hashrate      66.12 -> 79.63 MH/s   (+20.4%)
    shares        2143 found, 2143 accepted, 0 REJECTED
    FIFO_STAT     0x0000 -- not one find dropped at the higher rate
    temperature   stable at 62 C, fan 55% / 3000 rpm

Both builds scale at ~0.50 x clk_h, so the scaling is linear and the 158 MHz
figure was not optimistic. The thermal result is the one that mattered for
committing to flash: 20% more work settled at 62 C, inside the fabric curve's
55-70 C band with room before it steps to 75%.

FOUR CHANGES in each, batched onto the compulsory epoch rebuild:

  * `encrypt.v` at seed 1788480000 with `ODO_SEED` matched (rollover build).
    Before regenerating, ./odo_gen 1787616000 4 encrypt_4 was verified to
    reproduce the in-tree encrypt.v byte-for-byte, so the tool and flags were
    provably the ones that built what was running.
  * clk_h 133.33 -> 158.33 MHz (MMCM MULT 16 -> 19), both miner instances.
  * found_path's `soft_reset` with OP_SOFT_RESET driving it and the daemon
    issuing one at startup -- the fix for the wedge in item 8.
  * UART_STAT able to report a full TX FIFO, plus the ESP32 IO0 polarity fix.

Timing, both builds: 158.333 MHz, 0 routing errors, 0 failing endpoints, hold
met. WNS +0.449 ns (current epoch) and +0.548 ns (rollover). Those are not
comparable with 0x0201's 1.468 ns -- that was slack against a 7.500 ns period,
these are against 6.316 ns. The design got faster, not slower.

A SUPERSEDED_ artifact carries an earlier 0x0203 with the IO0 polarity bug;
its md5 differs from the fixed one, confirming the fix is really in. It is
kept only so the two cannot be confused.

**After flashing the rollover build, re-run `tools/check-epoch.sh`** - it
should report CURRENT, and the daemon's staleness check compares ODO_SEED
against the pool's job epoch, so a mismatch shows up as rejects rather than
silence.

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

---

## 8. The FPGA can wedge across a miner restart, and only a reload clears it

Seen 2026-09-01 16:10. The miner was stopped and restarted to deploy a new
binary. It came back, connected to the pool, took jobs -- and never dispatched
a single one. Hashrate 0, shares 0, indefinitely.

**It was not the software.** Restoring the previous, known-good binary left it
equally dead, which is what ruled the deploy out. The registers told the real
story:

    STATUS     0x0001   hash_active=1  nonce_valid=0
    FIFO_STAT  0xff00   lost=255 (SATURATED)  depth=0

The core was still hashing and still finding nonces, but the host never
consumed them: the found-FIFO overflowed until its lost counter saturated, and
the main thread sat in `do_sys_poll` -- waiting on an IRQ edge that was never
going to arrive.

**Root cause found, and it is not what this note first said.** I wrote it up
as a SIGTERM landing mid-transaction, leaving the 4-phase handshake
half-completed. That was wrong: the daemon's signal handling is cooperative
(`on_sig` sets a flag, the loops exit between iterations) and the failing
shutdown logged a clean `[pipe] exit: found=3417 shares=3408 stale=9`.

The actual cause is in `found_path.v`. Its `busy` flag is set when a nonce is
handed to the bus domain and was clearable ONLY by the host's ack -- and the
module had NO RESET INPUT AT ALL, so `busy` took its initial value only at
configuration. If the host stops polling while a nonce is outstanding, `busy`
latches with no ack ever coming and the handoff stalls permanently. At ~15
finds/sec that window is open essentially all the time, so any orderly
shutdown can do it. Nothing host-side could clear it: OP_SOFT_RESET did not
reach the module, `commit` deliberately preserves `busy`, and the daemon never
issued a soft reset anyway.

FIXED in 9e6c6df -- found_path gains a `soft_reset`, OP_SOFT_RESET drives it,
and the daemon issues one at startup after reading and reporting FIFO_STAT.
tb_found_path's T9 reproduces the wedge and proves the recovery. NEEDS A
BITSTREAM to take effect.

**Recovery, which works and takes seconds:**

    systemctl stop odo-miner
    am01-fpga-reload            # reloads from flash over JTAG
    systemctl start odo-miner

Immediately after: `STATUS 0x0000`, `FIFO_STAT 0x0000`, and mining resumed at
67.7 MH/s with 461 found / 461 accepted.

**Worth fixing properly**, because this will happen again on any deploy:

  * a SIGTERM handler that finishes the in-flight transaction before exiting,
    or refuses to die mid-cycle
  * and/or a bus-recovery routine at startup -- deassert WR_N/RD_N, wait for
    READY to drop, and only then proceed. Cheap, and it would make the daemon
    self-healing rather than needing JTAG.
  * `FIFO_STAT`'s lost counter is the tell. A saturated 255 with a live
    `hash_active` means finds are being dropped on the floor; nothing
    currently surfaces that, and it deserves to be in status.json where the
    dashboard would show it.

Until then: if the miner comes back from a restart with hashrate 0, read
`am01_reg` before assuming the deploy was at fault, and reload the FPGA.
