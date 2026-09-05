# JP5 — display, touch, fan and CYD wiring

Everything the AM01 adds to the QMTECH board — the ILI9341 panel, its XPT2046
touch controller, and the fan — connects through **JP5**, the board's 50-pin
expansion header. Nothing else is needed: no breakout, no rework.

> ## CORRECTED 2026-08-31 -- THE PIN NUMBERS WERE OFF BY TWO
>
> Every signal in this file used to be listed two pins low. The header is:
>
> | pins | |
> |---|---|
> | 1, 2 | **GND** |
> | 3, 4 | **VCCO_12 (3.3 V)** |
> | 5..46 | the 21 BANK12 signal pairs |
> | 47, 48 | **GND** |
> | 49, 50 | **5V0** |
>
> That sums to 50. The old table did not: it started the signals at pin 3, ran
> out at 44, and left 45-48 as four grounds with no VCCO_12 pair anywhere.
> The arithmetic never closed and nobody checked it.
>
> **What this broke.** The fan's PWM and tach were wired to 43/44 -- which are
> `V23`/`V24`, unconnected in this design -- instead of 45/46. The display was
> wired to 3..11 instead of 5..13. Hours were spent looking for faults in the
> RTL, the fan, and two different wiring conventions, when the header mapping
> was wrong the whole time.
>
> **It also invalidated a conclusion recorded here earlier.** The panel would
> not power from "pin 1", and this document concluded it must therefore be a
> 5 V module. Pin 1 is GROUND. The 3.3 V pair is 3/4 and was never tried, so
> the panel may well run at 3.3 V after all -- and the 5 V warning below is
> unproven. Test 3.3 V from pin 3 before accepting it.
>
> Confirmed empirically before this edit: forcing PWM duty made **pin 45**
> swing 1.32 V -> 3.30 V under software control, and **pin 46** sat at its
> internal pull-up. Both match the corrected table, neither matches the old one.

## What JP5 is

`HDR_25X2`, a 50-pin (25×2) header carrying **42 bank-12 FPGA signals** plus
power and ground. Every net on it is named `BANK12_<ball>`, so the schematic
label tells you the FPGA pin directly.

**Bank 12 runs at 3.3 V.** All the signals below are `LVCMOS33` in
`xdc/qmtech_xc7k325t_pinout.xdc`. This matters: an earlier revision declared
`lcd_miso` as `LVCMOS18` and Vivado rejected the design, because a bank has one
I/O voltage and it cannot be both.

### Provenance

Read from the vendor schematic
(`reference/hardware/QMTECH-XC7K325T-DEVELOPMENT-BOARD_SCHEMATIC_20231120_V01.pdf`,
sheet 3), by rendering the JP5 symbol at 400 dpi and reading the pin numbers
and net labels off it directly — not inferred, and not read off a photograph.
Each ball in the XDC was then confirmed to exist as a `BANK12_<ball>` net on
that sheet.

This check was worth doing rather than assuming: the case documentation had
recorded the display parts as "borrowed from a different board, not verified
against this one", so it was genuinely possible the pins went nowhere useful.
They don't — the XDC assignment uses the first nine signal pins of JP5 in
order, which looks deliberate.

## Full pin map

| Pin | Net | | Pin | Net |
|----:|-----|-|----:|-----|
| 1 | **GND** | | 2 | **GND** |
| 3 | **VCCO_12 (3.3 V)** | | 4 | **VCCO_12 (3.3 V)** |
| 5 | BANK12_AD21 | | 6 | BANK12_AE21 |
| 7 | BANK12_AE22 | | 8 | BANK12_AF22 |
| 9 | BANK12_AE23 | | 10 | BANK12_AF23 |
| 11 | BANK12_V21 | | 12 | BANK12_W21 |
| 13 | BANK12_Y22 | | 14 | BANK12_AA22 |
| 15 | BANK12_AF24 | | 16 | BANK12_AF25 |
| 17 | BANK12_AB21 | | 18 | BANK12_AC21 |
| 19 | BANK12_AB22 | | 20 | BANK12_AC22 |
| 21 | BANK12_AD23 | | 22 | BANK12_AD24 |
| 23 | BANK12_AC23 | | 24 | BANK12_AC24 |
| 25 | BANK12_AD25 | | 26 | BANK12_AE25 |
| 27 | BANK12_AA23 | | 28 | BANK12_AB24 |
| 29 | BANK12_AA25 | | 30 | BANK12_AB25 |
| 31 | BANK12_Y23 | | 32 | BANK12_AA24 |
| 33 | BANK12_AD26 | | 34 | BANK12_AE26 |
| 35 | BANK12_AB26 | | 36 | BANK12_AC26 |
| 37 | BANK12_W23 | | 38 | BANK12_W24 |
| 39 | BANK12_Y25 | | 40 | BANK12_Y26 |
| 41 | BANK12_W25 | | 42 | BANK12_W26 |
| 43 | BANK12_V23 | | 44 | BANK12_V24 |
| 45 | BANK12_U24 | | 46 | BANK12_U25 |
| 47 | **GND** | | 48 | **GND** |
| 49 | **5V0** | | 50 | **5V0** |

## Display and touch — REMOVED 2026-09-05

The ILI9341 panel and its XPT2046 touch controller were driven directly by the
FPGA over JP5 5–13. **That whole path is gone**, in RTL, in the pin
constraints, and in the CM4 driver (`am01_panel.c`).

The CYD front panel replaced it: an ESP32 with its own display and touch,
reached over a single pair of wires, updatable from the miner without opening
the case. Keeping both would have meant maintaining two panels, a shared SPI
engine, a touch sequencer, eight register addresses and nine pins — for a
display that was strictly worse and needed the case open to change.

### Nine pins are now free

| JP5 | Ball | was |
|---|---|---|










A contiguous run of 5–13, all on BANK12 (3.3 V). Register addresses `0x10`–
`0x17` are free with them.

**If you constrain any of these, do it one line per pin.** When the old block
used a `foreach` loop, `lcd_miso` came out of synthesis with no IOSTANDARD at
all, Vivado defaulted it to LVCMOS18, and DRC failed the entire implementation
on a bank 12 Vcc conflict.

The history of this path — the SPI multiplexing that was tried and abandoned,
the 5 V panel supply, the level-shifter hazard on `T_DO` — is in the git
history and in `CODE-REVIEW-2026-08-30.md`. It is not repeated here, because
this file should describe what is wired now.

## Fan — 4-wire PWM

| JP5 pin | FPGA ball | RTL port | Fan wire |
|--------:|-----------|----------|----------|
| 45 | U24 | `fan_pwm` | blue — PWM in |
| 46 | U25 | `fan_tach_in` | yellow — tach out |
| 47/48 | — | — | black — GND |
| 49/50 | — | — | red — +5 V |

A whole 4-wire fan wires into the bottom corner of the header.

Control is autonomous in fabric — the FPGA reads XADC die temperature and steps
duty 30/40/55/75/100% at 40/55/70/85 °C. The fail-safe is deliberate: a raw
XADC code of `0x0000` means *temperature unknown* and runs the fan at **100%**,
never 0%. An unknown temperature must never be treated as a cold one.

## CYD front panel — ESP32 serial link

An alternative to the ILI9341 above: an ESP32 "Cheap Yellow Display" driving its
own panel, linked to the FPGA by a UART. See `docs/PLAN-cyd-display.md`.

| JP5 pin | FPGA ball | RTL port | CYD pin |
|--------:|-----------|----------|---------|
| 15 | AF24 | `cyd_uart_tx` | RX (GPIO3) |
| 16 | AF25 | `cyd_uart_rx` | TX (GPIO1) |
| 17 | AB21 | `cyd_esp_en` | EN |
| 18 | AC21 | `cyd_esp_io0` | IO0 |
| 47/48 | — | — | GND |
| 49/50 | — | — | +5 V (VIN) |

**These are its own pins, not the display's.** An earlier revision multiplexed
the link onto `lcd_sclk`/`lcd_miso`/`lcd_cs_n`/`lcd_dc` behind a build-time
`PANEL_IF` parameter, which forced a choice of one panel or the other and left
four port names describing hardware they no longer drove. There was never a
need for that: this design constrains 15 of JP5's 42 signal pins, so pins 14
and 19–44 are still free. One bitstream now serves either panel, and both can
be wired at once.

Pin 14 (`AA22`) is deliberately skipped, so the display block (5–13) and this
one do not run into each other when counting along the header.

Both ends are 3.3 V — bank 12's VCCO is the 3V3 rail and the ESP32 is a 3.3 V
part — so unlike the ILI9341 there is no level-shifting question here.

`cyd_uart_rx` has `PULLUP true` in the XDC. Without it the pin floats when no
CYD is attached, drifts across the input threshold, and reads as a stream of
start bits — filling `rx_err` with framing errors on a board that has no panel
at all.

**Note the crossover.** TX goes to RX. Wiring TX–TX is the classic way to get a
link where neither end hears anything and both look healthy.

**At the CYD end this is connector P5**, a 4-pin JST carrying `VIN, TX, RX,
GND` - power and the serial link together, so no soldering and no header work.
Read off the board 2026-09-01 (silkscreen `ESP32-2432S028`). CONFIRM WHICH
PHYSICAL PIN IS WHICH WITH A METER before plugging in: reversing VIN and GND
destroys the panel, and that is not something to take off a photograph.

### The FPGA -> CYD direction has never worked, and it is P5's RX pin

**Status 2026-09-03: the panel receives nothing, on two separate boards.** The
CYD's own transmit reaches JP5 16 perfectly; nothing the FPGA sends is ever
acted on. Everything except one link is now measured rather than assumed, so
this records what was eliminated, to stop it being re-investigated.

Ruled out, in order:

| Layer | How | Result |
|---|---|---|
| Wire format | `sim/tb_uart_tx_pin.v` decodes the pin with a receiver written from the RS-232 spec, sharing no code with the DUT. 0x55 and 0xAA are each other's bit-reversal AND inversion | conformant |
| Pin placement | `io_placed` report: AF24, LVCMOS33, OUTPUT | correct |
| Pin driver | timing report: `uart_i/uart_tx_reg` (FDSE) -> OBUF -> AF24, real path | not tied off |
| Baud | one `DIVISOR` shared by TX and RX; the RX direction decodes correctly | 115200 both ways |
| Throughput | `txstream`: ~2.07M bytes in a nominal 180s, 11451-11580 B/s | line rate |
| JP5 15 identity | jumper JP5 15-16, `am01-uartd selftest` | 28/28 bytes, so AF24 really is JP5 15 |
| Both wires | same jumper moved to the CYD end | 28/28 bytes, wires perfect |
| Contention | `txstream 240 0x00` (90% low) measured 0.5V, implying a low near 0.19V against a 0.825V threshold | nothing fighting the driver |
| ESP32 state | `cap boot` reads the mode field: `boot:0x3 (DOWNLOAD_BOOT(UART0/...))`, `waiting for download` | listening |
| The board itself | a second, different CYD, same wires | identical silence |

**ANSWER, confirmed 2026-09-03.** P5's TX and RX reach GPIO1 and GPIO3 through
**100 ohm series resistors, R5 and R6**, and the CH340C USB-serial converter is
wired to those same two GPIOs *directly*. This is documented CYD behaviour, not
a fault on these units, which is why two different boards behaved identically.

Why that kills this direction and not the other:

* **Panel -> FPGA works.** GPIO1 is an ESP32 output. It drives out through R5
  into our high-impedance FPGA input; the 100 ohms costs nothing.
* **FPGA -> panel cannot work.** The CH340C's TX is a powered push-pull output
  sitting directly on GPIO3. Our driver reaches that node only through R6, so
  the two form a divider that the CH340 wins:

        V(GPIO3) = 3V3 x (R_fpga + R6) / (R_ch340 + R6 + R_fpga)

  With ~30 ohms of FPGA driver, R6 = 100 and a CH340 output near 50 ohms, GPIO3
  sits around 2.4 V when we are asserting a ZERO. The ESP32 needs below 0.825 V
  (0.25 x VDD). It reads a permanent 1 and never sees a single bit.

**This is why the measurements looked healthy.** Metering the P5 pin reads our
own side of R6, where the swing genuinely is clean -- measured 0.5 V average on
0x00 (90% low) and 1.77 V on 0x55 (50% duty), the latter matching a 3.3 V high
against a ~0.23 V low to within 5 mV. The contention is on the FAR side of the
resistor and is invisible from the connector.

Community reports match exactly: "the P1 port RX (GPIO3) wasn't receiving data
from an Arduino Pro Mini, but TX worked in the opposite direction."

### Two ways forward

**A. Keep flashing over the wires -- requires board rework.** Stop the CH340C
driving GPIO3, and drop R5/R6 so our driver is not attenuated. The documented
recipe is to remove the CH340 and replace R5 and R6 with 0R links ("you may get
away with 20R, but 100R is too high"). Lifting only the CH340's TXD pin is the
smaller version of the same idea. Per panel, and irreversible in practice.

**B. Move the link off UART0 -- no rework. THIS IS WHAT IS IMPLEMENTED.**
UART0 is needed only for FLASHING. CN1 carries `GND, IO22, IO27, 3V3`, none of
it touched by the CH340, and all four of those GPIOs are free on this board:
the display uses 2/12/13/14/15/21, touch 25/32/33/36/39, the SD card 5/18/19/23
and the RGB LED 4/16/17.

`cyd_link_uart.cpp` now opens:

    Serial2.begin(115200, SERIAL_8N1, /*RX=*/27, /*TX=*/22);

The pins MUST be given explicitly: Serial2 defaults to GPIO16/17, which are the
RGB LED.

### Wiring for the CN1 link

| FPGA | Direction | CYD |
|---|---|---|
| JP5 15 (`cyd_uart_tx`, AF24) | -> | **CN1 IO27** |
| JP5 16 (`cyd_uart_rx`, AF25) | <- | **CN1 IO22** |
| JP5 47/48 (GND) | -- | P5 GND |
| **5 V** supply | -- | P5 VIN |

**5 V, NOT 6 V.** The 6 V figure below belongs to the QMTECH FPGA board, whose
U17 bucks 5V0 down from VIN and cannot regulate if VIN is already 5 V. Both
boards call their input VIN, which makes them easy to conflate. The CYD is a
USB-powered part: its AMS1117 makes 3V3 from the USB 5 V rail, and P5's VIN is
that same node. It has run all evening on 5 V.

P5's TX and RX are now UNUSED -- leave them unconnected.

**Why two wires on each connector rather than four on one.** Ground is common,
so it is not worth duplicating: CN1 needs only its two GPIOs. No single
connector carries both a 5 V input and two free GPIOs -- CN1's fourth pin is
3V3, not VIN. Powering through CN1's 3V3 instead is possible, and would put all
four wires on one connector, but it backfeeds the AMS1117's output and needs a
clean 3V3 supply able to carry the display and backlight. Feeding 5 V into it
would destroy the panel. Not worth it to save a connector.

The panel is flashed over USB. `cyd_esp_en` / `cyd_esp_io0` on JP5 17/18 no
longer have a role in flashing, since the ROM bootloader only listens on UART0,
but they remain useful for resetting a wedged panel from the miner.

Two consequences of the move, both improvements: USB and the link no longer
share a pair, so the USB console is free; and `Serial.print()` debugging is safe
again, because it goes to USB rather than down the link.

Sources: atomic14's CYD board notes; witnessmenow/ESP32-Cheap-Yellow-Display
discussion #113.

The other two JSTs do NOT carry EN or IO0 - P3 is `GND, IO35, IO22, IO21`
(IO35 is input-only, ESP32 34-39) and CN1 is `GND, IO22, IO27, 3.3V`. The plan
had assumed those signals would be available; they are not. So `cyd_esp_en`
and `cyd_esp_io0` on JP5 17/18 have nowhere to land, and the ESP32 is instead
expected to enter its ROM bootloader in software
(`RTC_CNTL_FORCE_DOWNLOAD_BOOT`, not yet verified on hardware). The two JP5
pins stay constrained and driven to their inactive states; wire them to the
RST/BOOT button pads only if you want to recover a bricked panel without
opening the case. See `cyd/README.md`.

## Power, and two things that will bite

**There is no 12 V on this board.** The rails are `VIN` (6 V in), `5V0`, `3V3`,
`1V8`, `1V5`, `1V0` — every one produced by a **buck** converter, which only
steps down. No `12V` net exists anywhere in the schematic. **Fit a 5 V fan.**

**If you insist on a 12 V fan, the tach will destroy an FPGA pin** unless you
are careful. It is an open-collector output: pulled up to 12 V it presents 12 V
to a 3.3 V input. Wire the fan's tach *directly* to pin 46 with **no external
pull-up** — the FPGA's own 3.3 V pull-up is already enabled — and share ground
between the two supplies. `fan_pwm` at 3.3 V drives a real 4-wire fan's PWM
input correctly; the standard specifies 3.3 V logic for it.

**`fan_pwm` cannot switch a 2-wire fan.** It is a logic output, not a power
switch; that needs a MOSFET.

**The 5V0 rail comes from VIN.** The board must be fed **6 V**, per the manual —
`U17` bucks 5V0 down from VIN and cannot regulate when VIN is already 5 V.
Running from 5 V leaves the board under-volted (`get_throttled` bit 0 set), and
hanging a fan off 5V0 makes it worse. Size the supply for the fan as well.

## Signals alternate sides

Consecutive signals are on **opposite rows**: `lcd_sclk` is pin 5 and
`lcd_mosi` is pin 6, so they face each other rather than sitting next to each
other. Count along the odd row (5, 7, 9, 11, 13) and the even row (6, 8, 10, 12)
separately when making a loom.

## Case implication

JP5 is on the board's **bottom edge**, alongside the USB cluster, and its case
cutout now has to pass the display ribbon, the touch lines and the fan lead. It
is load-bearing, not optional — see `case/README.md`.
