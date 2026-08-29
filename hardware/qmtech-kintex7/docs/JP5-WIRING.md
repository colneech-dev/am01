# JP5 — display, touch and fan wiring

Everything the AM01 adds to the QMTECH board — the ILI9341 panel, its XPT2046
touch controller, and the fan — connects through **JP5**, the board's 50-pin
expansion header. Nothing else is needed: no breakout, no rework.

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
| 1 | **VCCO_12 (3.3 V)** | | 2 | **VCCO_12 (3.3 V)** |
| 3 | BANK12_AD21 | | 4 | BANK12_AE21 |
| 5 | BANK12_AE22 | | 6 | BANK12_AF22 |
| 7 | BANK12_AE23 | | 8 | BANK12_AF23 |
| 9 | BANK12_V21 | | 10 | BANK12_W21 |
| 11 | BANK12_Y22 | | 12 | BANK12_AA22 |
| 13 | BANK12_AF24 | | 14 | BANK12_AF25 |
| 15 | BANK12_AB21 | | 16 | BANK12_AC21 |
| 17 | BANK12_AB22 | | 18 | BANK12_AC22 |
| 19 | BANK12_AD23 | | 20 | BANK12_AD24 |
| 21 | BANK12_AC23 | | 22 | BANK12_AC24 |
| 23 | BANK12_AD25 | | 24 | BANK12_AE25 |
| 25 | BANK12_AA23 | | 26 | BANK12_AB24 |
| 27 | BANK12_AA25 | | 28 | BANK12_AB25 |
| 29 | BANK12_Y23 | | 30 | BANK12_AA24 |
| 31 | BANK12_AD26 | | 32 | BANK12_AE26 |
| 33 | BANK12_AB26 | | 34 | BANK12_AC26 |
| 35 | BANK12_W23 | | 36 | BANK12_W24 |
| 37 | BANK12_Y25 | | 38 | BANK12_Y26 |
| 39 | BANK12_W25 | | 40 | BANK12_W26 |
| 41 | BANK12_V23 | | 42 | BANK12_V24 |
| 43 | BANK12_U24 | | 44 | BANK12_U25 |
| 45 | **GND** | | 46 | **GND** |
| 47 | **GND** | | 48 | **GND** |
| 49 | **5V0** | | 50 | **5V0** |

## Display — ILI9341, SPI

| JP5 pin | FPGA ball | RTL port | Panel pin |
|--------:|-----------|----------|-----------|
| 3 | AD21 | `lcd_sclk` | SCK / CLK |
| 4 | AE21 | `lcd_mosi` | SDI / MOSI |
| 5 | AE22 | `lcd_miso` | SDO / MISO |
| 6 | AF22 | `lcd_cs_n` | CS |
| 7 | AE23 | `lcd_dc` | DC / RS |
| 8 | AF23 | `lcd_rst_n` | RESET |
| 9 | V21 | `lcd_bl` | LED / BL |

## Touch — XPT2046

| JP5 pin | FPGA ball | RTL port | Panel pin |
|--------:|-----------|----------|-----------|
| 10 | W21 | `touch_cs_n` | T_CS |
| 11 | Y22 | `touch_irq` | T_IRQ / PENIRQ |

The touch controller **shares the SPI bus** with the panel — `T_CLK`, `T_DIN`
and `T_DO` go to the same pins 3, 4 and 5. Only chip select is separate. That
is why a combined module (e.g. the KMRTM28028-SPI) needs just these nine
signals.

`touch_irq` is open-drain on the panel and has `PULLUP true` in the XDC, so no
external pull-up is required.

## Fan — 4-wire PWM

| JP5 pin | FPGA ball | RTL port | Fan wire |
|--------:|-----------|----------|----------|
| 43 | U24 | `fan_pwm` | blue — PWM in |
| 44 | U25 | `fan_tach_in` | yellow — tach out |
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

Consecutive signals are on **opposite rows**: `lcd_sclk` is pin 3 and
`lcd_mosi` is pin 4, so they face each other rather than sitting next to each
other. Count along the odd row (3, 5, 7, 9, 11) and the even row (4, 6, 8, 10)
separately when making a loom.

## Case implication

JP5 is on the board's **bottom edge**, alongside the USB cluster, and its case
cutout now has to pass the display ribbon, the touch lines and the fan lead. It
is load-bearing, not optional — see `case/README.md`.
