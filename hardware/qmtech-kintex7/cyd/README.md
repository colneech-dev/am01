# CYD front panel — scaffolding

An ESP32 "Cheap Yellow Display" (ESP32-2432S028R class) as the AM01's front
panel: 320x240 RGB565 with an XPT2046 resistive touch controller.

**Nothing here is wired into the build yet, and nothing here modifies the
existing ILI9341 panel path.** That solution is still being pursued; this is a
parallel track. The files it would eventually replace —
`cm4-firmware/am01_panel.c` and the display block inside
`hdl/odocrypt_gpio_wrapper.v` — are deliberately untouched.

See `docs/PLAN-cyd-display.md` for the design and the reasoning behind it.

## Why this exists

The current panel is nine jumper wires from JP5 carrying SPI at 6.25 MHz, and
it has never worked. Two panels, a decoupling capacitor, several rewires, a
corrected MADCTL orientation and a genuine driver bug fixed — still a white
screen. Every software hypothesis was eliminated; what remains is the physical
layer.

A CYD puts the panel and its controller on one PCB and reduces the link to
four slow signals.

## Layout

    cyd/
      host/       runs on the CM4 -- the UART bridge daemon and its protocol
      firmware/   runs on the ESP32 -- the UI

    hdl/uart_bridge.v          FPGA-side UART + ESP EN/IO0, instantiated by
                               odocrypt_gpio_wrapper.v on JP5 15-18
    sim/tb_uart_bridge.v       its testbench -- 22 checks, all passing

## The constraint

No CM4 GPIO reaches a connector. All 28 are wired CM4↔FPGA and 25 are in use,
so the three spare ones terminate at FPGA balls. Every wire leaving this board
leaves through JP5, which is FPGA BANK12. The link can therefore only be:

    Pi --(existing parallel bus)--> FPGA --(JP5)--> CYD

That is not a workaround; it is the only topology the hardware allows.

It does NOT, however, mean the display has to be given up to make room. That
was the original assumption here -- that the CYD would take over JP5 5-13 as
the ILI9341 vacated them -- and it was simply wrong about how much of the
header was spoken for. JP5 carries 42 BANK12 signal pins; this design
constrains 15.

## Wiring

| JP5 | Ball | RTL port | CYD pin |
|---:|---|---|---|
| 15 | AF24 | `cyd_uart_tx` | RX (GPIO3) |
| 16 | AF25 | `cyd_uart_rx` | TX (GPIO1) |
| 17 | AB21 | `cyd_esp_en` | EN |
| 18 | AC21 | `cyd_esp_io0` | IO0 |
| 47/48 | | GND | GND |
| 49/50 | | +5V | VIN |

**Its own pins.** No mux, no build-time parameter, no either/or: the display
block is untouched, one bitstream serves both panels, and a CYD can be brought
up on a board whose ILI9341 is still wired -- which matters, because the
ILI9341 is the thing that does not work and is being diagnosed.

### The CYD end: connector P5

Read off the board on 2026-09-01 (silkscreen `ESP32-2432S028`, panel
`TPM408-2.8`), not inferred:

| Connector | Pins | Use |
|---|---|---|
| **P5** | `VIN, TX, RX, GND` | **this is the one.** Power and UART on one 4-pin JST |
| P3 | `GND, IO35, IO22, IO21` | general GPIO. IO35 is INPUT-ONLY (ESP32 34-39) |
| CN1 | `GND, IO22, IO27, 3.3V` | general GPIO + 3.3V |
| SPEAK | 2-pin | speaker amp |

P5 means no soldering and no header work: one plug carries 5V, GND, TX and RX.

**CONFIRM P5's PIN 1 WITH A METER BEFORE PLUGGING ANYTHING IN.** The labels are
legible but which physical end is which is not something to take off a
photograph, and reversing VIN and GND destroys the board. Continuity from the
GND pin to a mounting hole settles it.

**NEITHER P3 NOR CN1 BREAKS OUT EN OR IO0.** That was checked specifically,
because the plan assumed they would be available. They are not, and IO35 is
input-only so it cannot substitute.

### Which means cyd_esp_en / cyd_esp_io0 are OPTIONAL

JP5 17/18 have nowhere to land. Rather than solder to the RST/BOOT button
pads, the ESP32 can enter its own ROM bootloader in software:

    REG_WRITE(RTC_CNTL_OPTION1_REG, RTC_CNTL_FORCE_DOWNLOAD_BOOT);
    esp_restart();

The firmware accepts an "enter bootloader" command over the same UART, sets
that bit, reboots, and esptool takes over on the same four wires. NOT YET
VERIFIED ON HARDWARE -- it is the documented mechanism for ESP32 classic, but
prove it before relying on it.

That leaves the four-wire link doing everything: status, commands and
firmware updates, over one JST.

**The fallback still exists and does not need us to design for it.** If the
firmware is bricked it cannot act on the command -- but the ROM bootloader is
in mask ROM and the board has RST and BOOT buttons, so holding BOOT and
tapping RST always works. Wire JP5 17/18 to those button pads only if you want
to recover a bricked panel without opening the case.

**This board has BOTH micro-USB and USB-C**, so a first flash needs no wiring
at all. But P5's TX/RX are GPIO1/GPIO3, the same pair the onboard USB-serial
chip drives: never have USB connected while P5 is plugged into the FPGA.

TX goes to RX. Wiring TX-TX gives a link where neither end hears anything and
both look healthy.

Both sides are 3.3V logic, so no level shifting. A 115200-baud bit period is
8.7us against the failing SPI's 160ns — roughly fifty times the timing margin,
on four wires instead of nine.

## Status

| Piece | State |
|---|---|
| `docs/PLAN-cyd-display.md` | written |
| `case/v4-cyd` lid | rendered, printable |
| `host/am01-uartd` | register accessors done, cross-builds; `selftest` usable. PTY layer not started |
| `host/cyd_proto.h` | protocol defined, compiled by BOTH halves |
| `firmware/cyd_link.h` | link interface; UART only, WiFi removed |
| `firmware/cyd_ui.h` | screen model, ported from odo-ui |
| `firmware/cyd_ui.c` | navigation + touch, 41/41 checks |
| `firmware/cyd_fmt.c` | value formatters, 29/29 checks |
| `firmware/board_probe.cpp` | **FLASHED AND PASSING on real hardware, 2026-09-01** |
| `firmware/main.cpp` | does NOT link -- cyd_link_uart_* and cyd_ui_draw unimplemented |
| `hdl/uart_bridge.v` | 22/22, instantiated on JP5 15-18 |
| bitstream | VERSION 0x0202 built; the 158 MHz build carries it at the current epoch |

## Hardware bring-up result, 2026-09-01

`board_probe` flashed and run on the real panel. **Display and touch both
work**, which retires the biggest risk on this track.

    === AM01 CYD board probe ===
    tft: 240x320
    bar: RED / GREEN / BLUE / WHITE
    ready -- touch the panel
    touch raw=(1967,2308) z=2042  mapped=(120,185)
    touch raw=(2258,1584) z=1819  mapped=(140,120)

**Touch reads correctly on its own VSPI bus.** That was the assumption most
likely to be wrong -- the CYD's display-on-HSPI / touch-on-VSPI split is why
so many sketches show a perfect display and a dead touchscreen. Leaving
TOUCH_CS unset for TFT_eSPI and driving the XPT2046 on a separate SPIClass is
confirmed correct.

Chip: ESP32-D0WD-V3 rev v3.1, 4MB flash, dual core 240MHz,
MAC c0:cd:d6:84:64:34.

### Flashing this board needs the BOOT button held

esptool CANNOT enter download mode on its own here. RTS -> EN is wired, so it
can reset the chip, but DTR -> IO0 is NOT, so it cannot select the boot mode:
every attempt reports "Wrong boot mode detected (0x13)". The sequence that
works is hold BOOT, tap RST, KEEP HOLDING BOOT through the whole operation --
each esptool invocation reopens the port and pulses RTS, and holding BOOT
means every one of those resets lands back in download mode.

This is the same missing-EN/IO0 problem the wired link has, seen over USB.

### RTC_CNTL_FORCE_DOWNLOAD_BOOT DOES NOT EXIST ON THIS CHIP

I proposed it as the way to flash with no extra wires: the firmware sets an
RTC bit, restarts, and the ROM comes up in download mode. Checked against the
SDK on 2026-09-01, and it is not available here.

`RTC_CNTL_OPTION1_REG` and `RTC_CNTL_FORCE_DOWNLOAD_BOOT` are defined only in
the **esp32c3** and **esp32s2** SoC headers. The esp32 (classic) header has
neither. This board is an ESP32-D0WD-V3 -- the original silicon -- so the
register was never there. I had carried the idea over from the newer chips
without checking.

It is not a UART-versus-USB question: the mechanism is a register write
inside the chip and would have been transport-independent. It simply does not
exist on this part.

**So wiring EN and IO0 is the ONLY route to hands-off flashing**, over USB or
over JP5. Two wires from JP5 17/18 to the RST and BOOT button pads, each with
~1k in series -- the FPGA drives push-pull, so without the resistor, pressing
a button while the FPGA holds that pin high shorts the output to ground. 1k
caps it at ~3.3mA and still swings both lines against their pull-ups and EN's
reset capacitor.

That also makes the IO0 polarity fix in 0bf4ea9 load-bearing rather than
tidy-up: with EN/IO0 wired and the old default, the panel would have sat in
download mode forever.

### The factory demo is backed up

    /c/tmp/cyd_backup/cyd_factory_4MB.bin   4,194,304 bytes

Taken before flashing anything. It is the known-good reference: if our
firmware misbehaves, restoring this re-establishes "the hardware is fine"
independently of our code -- exactly the discriminator the ILI9341 debugging
never had. MOVE IT SOMEWHERE PERMANENT; /c/tmp is not.

    esptool --chip esp32 --port COM8 --baud 921600             write_flash 0x0 cyd_factory_4MB.bin

### Touch calibration is NOT done

The raw values above are real but only cover the middle of the panel. The
RAW_X/Y_MIN/MAX constants in board_probe.cpp are the usual defaults, not
measured for this unit. Touch the four corners and read off the extremes
before the UI relies on them.

## Order of work

Per the plan, and deliberately not in the order that feels most fun:

1. ~~`hdl/uart_bridge.v` + `sim/tb_uart_bridge.v`~~ **done** — testbench
   first, as with `found_path.v`. 22/22.
2. `host/am01-uartd` — accessors **done**, provable against a loopback before
   any CYD exists (`am01-uartd selftest`, wire JP5 15 to 16). PTY layer next.
3. Firmware against the UART.
4. Commands last, once the display half is trusted.

There is no WiFi step. One was planned here — develop the UI over WiFi while
the RTL was in flight — and dropped on 2026-09-01, unimplemented: the RTL
landed, so the reason to defer was gone; it contradicted the requirement this
panel exists to meet (over wires, not USB, not WiFi); it was the *default* in
`main.cpp`, so a build would quietly have used it; and it would have meant
storing the network credentials a second time, in the firmware.

**Do not start before the 0x0201 core work is confirmed earning.** Same gate
`PLAN-adopt-cyclonev-core.md` sets, for the same reason: one unproven thing in
a bitstream at a time.
