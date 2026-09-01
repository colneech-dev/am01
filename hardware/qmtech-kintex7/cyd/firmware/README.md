# CYD firmware

Runs on the ESP32 of a "Cheap Yellow Display" (ESP32-2432S028R class).

**Scaffolding. Not built, not flashed, not wired into anything.** The existing
ILI9341 panel remains the live solution and is untouched.

## What it is

A front panel for the AM01 miner. It does not mine and it does not control the
FPGA — it displays the miner's status and sends commands back. See
`docs/PLAN-cyd-display.md` for why that is the only thing it can be (the
host↔FPGA link is a 24-line parallel bus terminating at the CM4 socket; a CYD
breaks out a handful of pins and there is no header exposing that bus).

## Why this is a port, not a design

`odo-miner-cyclonev/sw/odo-ui` already implements exactly this UI, at
**320x240 RGB565 against an XPT2046 resistive touch controller** — which is
precisely what a CYD is. Same resolution, same colour format, same touch
controller family, and it already consumes the same status object this panel
receives.

So the job is to keep its layout and behaviour and swap the backend:

| odo-ui (on the CM4) | here (on the ESP32) |
|---|---|
| Linux framebuffer `/dev/fb1` | TFT_eSPI / LVGL |
| evdev touch | XPT2046 over SPI |
| reads `/run/odod/status.json` | reads `STATUS {...}` from the UART |
| writes `/run/odod/` flag files | sends `CMD ...` over the UART |

`generated_screens/` and `mock_dashboard.png` in that tree are the reference
for what it should look like. Do not invent a new layout: the point of using
this panel is that the miner already has one.

## Screens (from odo-ui)

* **GLANCE** — hashrate, pool state, accepted/rejected, uptime
* **DETAIL** — plus epoch, job, fan, best difficulty, backend
* **SETTINGS** — dim level, dim timeout
* **ACTIONS** — RESET STATS, REBOOT, each behind a CONFIRM step

The confirm steps are not decoration. A panel that can reboot the miner on one
stray touch is a panel that eventually will.

## Files

    cyd_link.h / cyd_link.cpp   UART framing: read lines, parse STATUS, send CMD
    cyd_ui.h                    screen model, ported from odo-ui
    main.cpp                    setup/loop, wiring the two together

`cyd_proto.h` is shared with the host side and lives in `../host/`. One
definition, so the two halves cannot drift.

## Status

Nothing here compiles yet. The link layer is written against the protocol but
has no board support, and the UI is a header only. In the order the plan sets
out, the firmware is developed **against WiFi first** so the UI can progress
while `hdl/uart_bridge.v` is still in flight, then switched to the UART by
replacing one transport.

## Flashing

Over the same four wires, once `hdl/uart_bridge.v` and `am01-uartd` exist:

    esptool --port /dev/am01-cyd --before no_reset write_flash 0x0 firmware.bin

No cable, no button, no taking the panel out of the case. That is the whole
reason the host daemon presents a PTY rather than implementing the esptool
protocol itself.
