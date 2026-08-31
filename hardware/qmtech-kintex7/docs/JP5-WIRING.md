# JP5 — display, touch and fan wiring

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

## Display — ILI9341, SPI

| JP5 pin | FPGA ball | RTL port | Panel pin |
|--------:|-----------|----------|-----------|
| 1 or 2 | — | — | **VCC — see the 5 V warning below** |
| 5 | AD21 | `lcd_sclk` | SCK / CLK |
| 6 | AE21 | `lcd_mosi` | SDI / MOSI |
| 7 | AE22 | `lcd_miso` | SDO / MISO |
| 8 | AF22 | `lcd_cs_n` | CS |
| 9 | AE23 | `lcd_dc` | DC / RS |
| 10 | AF23 | `lcd_rst_n` | RESET |
| 11 | V21 | `lcd_bl` | LED / BL |

## Touch — XPT2046

| JP5 pin | FPGA ball | RTL port | Panel pin |
|--------:|-----------|----------|-----------|
| 12 | W21 | `touch_cs_n` | T_CS |
| 13 | Y22 | `touch_irq` | T_IRQ / PENIRQ |

The touch controller **shares the SPI bus** with the panel — `T_CLK`, `T_DIN`
and `T_DO` go to the same pins 5, 6 and 7. Only chip select is separate. That
is why a combined module (e.g. the KMRTM28028-SPI) needs just these nine
signals.

`touch_irq` is open-drain on the panel and has `PULLUP true` in the XDC, so no
external pull-up is required.

### PANEL SUPPLY: 5 V, NOT 3.3 V — measured 2026-08-30

This table used to say VCC goes to JP5 pin 1 (VCCO_12, 3.3 V). On the module
actually fitted that is WRONG and the panel stays dead: it powers only from
JP5 pin 49/50 (5 V).

The reason is an onboard linear regulator (U2 on this module) making 3.3 V for
the ILI9341. A 3.3 V input never reaches its dropout, so nothing comes up. That
regulator runs warm in normal use — dropping 5 V to 3.3 V while feeding a
backlight is a few tenths of a watt in a small package.

**A 5 V module has two consequences that a 3.3 V one does not:**

1. **Its logic OUTPUTS may be 5 V.** Bank 12 is a 3.3 V bank and its pins are
   NOT 5 V tolerant. If the module has a level shifter referenced to its 5 V
   rail, then `SDO` and `T_DO` swing to 5 V and connecting either of them to
   JP5 pin 7 can damage the FPGA. MEASURE `T_DO` against ground with the panel
   powered and idle before connecting it. Under ~3.6 V is safe; near 5 V is not,
   and needs a divider or a level shifter.

   This is also a second reason to leave the display's `SDO` unconnected — the
   design never reads it (see `spi_rx_en` in the wrapper), so it is pure risk.

2. **Its logic INPUTS may not see 3.3 V as a high.** A 5 V-referenced HC-family
   buffer wants Vih around 3.5 V, and the FPGA drives 3.3 V. HCT-family parts
   are fine at 3.3 V; HC parts are marginal. If the backlight lights but no
   image appears while the bus reports every write succeeding, this is the
   first thing to suspect — the FPGA cannot tell that nothing registered.

Powering the panel from 3.3 V instead would avoid both problems, but needs a
module without the regulator, or a bypass of it.

## Fan — 4-wire PWM

| JP5 pin | FPGA ball | RTL port | Fan wire |
|--------:|-----------|----------|----------|
| 45 | U24 | `fan_pwm` | blue — PWM in |
| 46 | U25 | `fan_tach_in` | yellow — tach out |
| 45–48 | — | — | black — GND |
| 49/50 | — | — | red — +5 V |

A whole 4-wire fan wires into the bottom corner of the header.

Control is autonomous in fabric — the FPGA reads XADC die temperature and steps
duty 30/40/55/75/100% at 40/55/70/85 °C. The fail-safe is deliberate: a raw
XADC code of `0x0000` means *temperature unknown* and runs the fan at **100%**,
never 0%. An unknown temperature must never be treated as a cold one.

## Power, and two things that will bite

**There is no 12 V on this board.** The rails are `VIN` (6 V in), `5V0`, `3V3`,
`1V8`, `1V5`, `1V0` — every one produced by a **buck** converter, which only
steps down. No `12V` net exists anywhere in the schematic. **Fit a 5 V fan.**

**If you insist on a 12 V fan, the tach will destroy an FPGA pin** unless you
are careful. It is an open-collector output: pulled up to 12 V it presents 12 V
to a 3.3 V input. Wire the fan's tach *directly* to pin 44 with **no external
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
