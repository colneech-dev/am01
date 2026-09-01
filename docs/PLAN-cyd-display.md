# Plan: CYD (ESP32 "Cheap Yellow Display") as the AM01 front panel

Replacing the JP5-wired ILI9341 with an ESP32-2432S028R-class board, linked to
the miner **over wires** (not USB, not WiFi), able to **control** the board as
well as display it, and **flashable in place** by the Pi.

Written 2026-08-31.

---

## Why

The current panel is nine jumper wires from JP5 running SPI at 6.25 MHz. It has
never worked reliably. Over one session: two panels, an added decoupling
capacitor, several rewires, a corrected MADCTL orientation, and a genuine
driver bug fixed (writes silently dropped while the shifter was busy) — and it
still shows nothing but a white screen. Every software hypothesis was
eliminated; what is left is the physical layer.

A CYD removes that layer entirely. The panel and its controller sit on one PCB
with proper traces, and the link to the miner becomes four slow signals instead
of nine fast ones.

**It is also the same display.** `odo-ui` already targets 320x240 RGB565 with an
XPT2046 resistive touch controller, which is exactly what a CYD carries. The UI
is a port, not a rewrite.

---

## The constraint that shapes everything

**No CM4 GPIO reaches a connector.** All 28 are wired CM4↔FPGA (README "GPIO
bus pinout"); 25 are in use (16 data, 5 address, WR_N, RD_N, READY, IRQ — GPIO24
became ADDR[4]), leaving GPIO25–27 spare *at FPGA balls*, not at a header.

So the Pi cannot be wired to anything directly. Every wire out of this board
leaves through JP5, which is FPGA BANK12. The link must therefore be:

    Pi  --(existing 24-line parallel bus)-->  FPGA  --(JP5)-->  CYD

The FPGA is already the only thing that can reach both. This is not a
workaround; it is the only topology the hardware allows.

Two consequences worth stating plainly:

* The three spare CM4 GPIOs are useless here. They terminate at FPGA balls and
  the BCM2711 has no UART alternate function on them anyway, so even a
  pass-through would be bit-banged.
* The ILI9341 does not have to be removed to make room. JP5 has 42 signal
  pins and only 15 are constrained, so the CYD gets its own (15–18) and the
  display keeps 5–13.

---

## Link design

A UART, hosted in the FPGA, driven by the Pi over the register bus it already
uses.

| JP5 pin | Ball | RTL port | Direction |
|---:|---|---|---|
| 15 | AF24 | `cyd_uart_tx` | FPGA -> CYD RX |
| 16 | AF25 | `cyd_uart_rx` | CYD TX -> FPGA |
| 17 | AB21 | `cyd_esp_en` | FPGA -> CYD reset |
| 18 | AC21 | `cyd_esp_io0` | FPGA -> CYD boot select |
| 47/48 | | GND | |
| 49/50 | | +5V | supply |

**ON ITS OWN PINS. Revised 2026-09-01, and this replaces two earlier
mistakes.**

This plan originally put the link on the display's pins 5-9, on the reasoning
that removing the ILI9341 freed them. Two things went wrong with that:

* Pin 6 is `lcd_mosi`, an **output**. A UART receiver there could never have
  received anything, and it would have presented as a panel that transmits
  fine and hears nothing.
* Reusing the pins at all forced a build-time `PANEL_IF` parameter choosing
  one panel or the other, and left `lcd_sclk`/`lcd_miso`/`lcd_cs_n`/`lcd_dc`
  as port names describing hardware they no longer drove.

Neither was necessary. JP5 carries 42 BANK12 signal pins and this design
constrains 15; pins 14 and 19-44 are free. Moving to 15-18 removes the mux,
the parameter, and the either/or: the display path is byte-for-byte unchanged,
one bitstream serves both panels, and the CYD can be brought up on a board
whose ILI9341 is still wired.

The premise in "The constraint that shapes everything" below is therefore
narrower than it first appeared: the link must still go Pi -> bus -> FPGA ->
JP5, but it does not have to displace anything to get there.

Four signals. Both sides are 3.3V logic (BANK12 is LVCMOS33, ESP32 is 3.3V), so
no level shifting.

**Why this is far more robust than what it replaces.** The failing link runs at
6.25 MHz over unterminated jumpers. A 115200-baud UART has a bit period of
8.7 microseconds against 160 nanoseconds — roughly fifty times the timing
margin, on half the wires. The same wiring that cannot carry the SPI will carry
this comfortably.

**Throughput is not a concern.** 115200 baud is 11.5 kB/s. The Pi's register
writes were measured at roughly 20 microseconds each on the LCD path
(76800 pixel writes in about 1.5 s), i.e. ~50k/s. Five times the headroom
needed. A small TX FIFO in the FPGA absorbs the burstiness so the Pi is not
obliged to feed it a byte at a time.

---

## Phase 1 — RTL: UART bridge + two GPIO bits

New `hdl/uart_bridge.v`, instantiated by the wrapper, plus registers:

| Addr | Name | Access |
|---|---|---|
| 0x19 | `UART_DATA` | write: push a TX byte / read: pop an RX byte |
| 0x1A | `UART_STAT` | read: `tx_free`, `rx_avail`, FIFO depths |
| 0x1B | `ESP_CTRL` | write: `[0]` EN, `[1]` IO0 |

Baud as a parameter (default 115200). TX and RX FIFOs, 16 deep, for the same
reason `found_path` has one: so a host that is briefly late does not lose data.

`ESP_CTRL` is deliberately two plain output bits. The ESP32 ROM bootloader is
entered by a specific EN/IO0 sequence, and that sequence belongs in software
where it can be adjusted, not baked into a state machine.

**Reuse the patterns, not the pins:** the display block's CDC approach and
register-decode style are proven and worth copying, and `found_path.v`'s FIFO
is a working model. Its *pins* are not reused — see the pin table above.

**Test it the way `found_path` was tested** — `tb_uart_bridge` driving the
module directly, loopback TX->RX, FIFO overflow, and a negative control.
That approach caught two real bugs before they reached a bitstream; the same
applies here.

---

## Phase 2 — Pi side: make it look like a serial port

`esptool` wants a tty. The FPGA UART is a register interface. Bridge them:

    am01-uartd  <->  /dev/pts/N  (symlinked /dev/am01-cyd)

A small daemon that shuttles bytes between a PTY master and `UART_DATA`,
polling `UART_STAT`. Then **everything downstream works unmodified**:

    esptool --port /dev/am01-cyd --before no_reset write_flash 0x0 cyd.bin

with the daemon driving `ESP_CTRL` for the reset-into-bootloader sequence.

This is the key move: it means firmware updates need no bespoke flashing code,
and the CYD can be reflashed from the Pi over the same four wires that carry its
normal traffic. No cable, no button, no removing it from the case.

---

## Phase 3 — Protocol

Line-oriented text, both directions. Not a binary protocol: this link carries a
status update a second and the occasional command, so legibility on a terminal
is worth far more than compactness — and this project has repeatedly been
slowed by things that were hard to observe.

**Pi -> CYD**, once a second: the existing status object, which already has
every field the UI needs. `/run/odod/status.json` is written by the miner and is
what both `odo-webd` and `odo-ui` already consume.

**CYD -> Pi**, on a touch:

    CMD fan_boost 1
    CMD reset_stats
    CMD reboot
    CMD set pool <host> <port> <worker> <pass>

`am01-uartd` applies them onto the control surface that already exists —
`/run/odod/fan_boost`, `/run/odod/reset_stats`, and for pool changes the boot
partition file `/boot/am01-miner.conf`, which the provisioning service already
installs and which survives a reflash. A pool changed from the panel therefore
persists, without inventing a second place config can live.

---

## Phase 4 — Firmware: port `odo-ui`, do not design a new UI

`odo-miner-cyclonev/sw/odo-ui` already implements what is wanted, at the CYD's
exact resolution and colour format, against this exact status schema:

* GLANCE and DETAIL screens
* HASHRATE, POOL, ACC/REJ, BLOCKS, EPOCH, FAN, JOB, LAST, BACKEND
* settings: DIM LEVEL, DIM TIMEOUT
* actions: RESET STATS, REBOOT, with CONFIRM steps
* an on-screen keyboard, already used for text entry

Port the layout and colours; replace the framebuffer/evdev backend with
TFT_eSPI (or LVGL) and the CYD's XPT2046. `generated_screens/` and
`mock_dashboard.png` are the reference for what it should look like.

Copy it into this repo rather than building against the sibling checkout —
same policy as `miner_pipe_am01.c` and `miner_pipelined.v`, and for the same
reason: different hardware under it.

---

## What this does NOT do

**The CYD cannot drive the FPGA or replace the CM4.** The host↔FPGA link is a
24-line parallel bus terminating at the CM4 socket. A CYD breaks out a handful
of GPIOs, several input-only, and there is no header exposing that bus to
contend for. The CYD is a front panel that can issue commands; the Pi remains
the host.

---

## Risks

| Risk | Mitigation |
|---|---|
| JP5 wiring is unreliable — the reason we are here | 115200 baud has ~50x the timing margin of the 6.25MHz SPI it replaces, over 4 wires not 9 |
| Register-bus throughput | measured ~50k writes/s vs 11.5k/s needed; FIFOs absorb bursts |
| ESP32 reset sequence is fiddly | it lives in software (`ESP_CTRL`), adjustable without a bitstream |
| A bad flash bricks the panel | ROM bootloader is in mask ROM and always recoverable over the same wires |
| New RTL, unproven | `tb_uart_bridge` before any bitstream, with a negative control |
| Scope creep into the core swap | strictly separate: this touches JP5 and a new register block, not the miner |

---

## Effort and sequencing

Roughly **3–4 days**, and it wants doing in this order:

1. Phase 1 RTL + testbench (can ride the next bitstream that is needed anyway)
2. Phase 2 `am01-uartd` + PTY — provable with a loopback before a CYD exists
3. Phase 4 firmware against the UART directly.

   THIS STEP USED TO SAY "against WiFi first, so the UI can be developed while
   the RTL is still in flight, then switched to the UART". Dropped 2026-09-01,
   never implemented. The RTL landed (uart_bridge.v, 22/22, registers live in
   a 0x0202 bitstream), so the reason to defer was gone -- and a WiFi
   transport contradicted this document's own opening line, "over wires (not
   USB, not WiFi)". It was also the DEFAULT in main.cpp, so a build would have
   quietly used it, and it would have meant storing the network credentials a
   second time in the firmware.
4. Phase 3 commands last, once the display half is trusted

**Do not start Phase 1 before the 0x0201 core work is confirmed earning.** That
is the same gate `PLAN-adopt-cyclonev-core.md` sets, for the same reason: one
unproven thing in a bitstream at a time.

---

## Open question

~~The CYD's light sensor position across the board's width was not measured~~
MEASURED 2026-09-01: 8-14mm in from the edge along the 50mm short axis.

The 26mm slot did NOT "catch it wherever it sits" -- centred on a 50mm module
it spanned 12-38mm from either edge, so the sensor fell almost entirely
outside it and the lid would have blinded it. Now an 8mm aperture at the
measured position, cut at both ends until the build orientation is fixed.
