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

    hdl/uart_bridge.v          (not yet written) FPGA-side UART + ESP EN/IO0
    sim/tb_uart_bridge.v       (not yet written) its testbench

## The constraint

No CM4 GPIO reaches a connector. All 28 are wired CM4↔FPGA and 25 are in use,
so the three spare ones terminate at FPGA balls. Every wire leaving this board
leaves through JP5, which is FPGA BANK12. The link can therefore only be:

    Pi --(existing parallel bus)--> FPGA --(JP5)--> CYD

That is not a workaround; it is the only topology the hardware allows. It also
happens to free exactly the pins needed, because the ILI9341 vacates JP5 5-13.

## Wiring (proposed)

| JP5 | Signal | Direction |
|---:|---|---|
| 5 | UART TX | FPGA -> CYD RX |
| 6 | UART RX | CYD TX -> FPGA |
| 7 | ESP_EN | FPGA -> CYD reset |
| 8 | ESP_IO0 | FPGA -> CYD boot select |
| 47/48 | GND | |
| 49/50 | +5V | supply |

Both sides are 3.3V logic, so no level shifting. A 115200-baud bit period is
8.7us against the failing SPI's 160ns — roughly fifty times the timing margin,
on four wires instead of nine.

## Status

| Piece | State |
|---|---|
| `docs/PLAN-cyd-display.md` | written |
| `case/v4-cyd` lid | rendered, printable |
| `host/am01-uartd` | skeleton, compiles, accessors stubbed |
| `host/cyd_proto.h` | protocol defined, shared by both halves |
| `firmware/cyd_link.h` | link interface, transport-agnostic |
| `firmware/cyd_ui.h` | screen model, ported from odo-ui |
| `firmware/main.cpp` | entry point, no board support yet |
| `hdl/uart_bridge.v` | not started |

## Order of work

Per the plan, and deliberately not in the order that feels most fun:

1. `hdl/uart_bridge.v` + `sim/tb_uart_bridge.v` — testbench first, as with
   `found_path.v`. That approach caught two real bugs before they reached a
   bitstream.
2. `host/am01-uartd` — provable against a loopback before any CYD exists.
3. Firmware, developed against WiFi so the UI can progress while the RTL is in
   flight, then switched to the UART.
4. Commands last, once the display half is trusted.

**Do not start before the 0x0201 core work is confirmed earning.** Same gate
`PLAN-adopt-cyclonev-core.md` sets, for the same reason: one unproven thing in
a bitstream at a time.
