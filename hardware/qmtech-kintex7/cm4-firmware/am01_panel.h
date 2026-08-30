/*
 * am01_panel -- ILI9341 output for the AM01 miner, driven cooperatively.
 *
 * The panel is not a Linux framebuffer device: it hangs off an SPI master
 * inside the FPGA, reachable only through the CM4<->FPGA GPIO bus. That bus
 * is opened EXCLUSIVELY -- the kernel hands gpiochip lines to one owner -- so
 * whatever pushes pixels cannot be a second process alongside odo-miner.
 *
 * Hence this is a library the miner calls, not a daemon. It is driven from
 * miner_io_pipe_wait()'s idle path: the miner blocks there waiting for the
 * nonce IRQ, and when that times out we know for certain no nonce is pending,
 * so the bus is free to borrow for a bounded slice.
 *
 * Three properties make that safe, and they are the point of the design:
 *
 *   - the slice is BOUNDED (am01_panel_slice takes a microsecond budget), so
 *     worst-case added nonce latency is one budget, chosen not hoped for;
 *   - it only ever runs after a wait timeout, so it never delays a nonce that
 *     has already arrived;
 *   - every failure is contained. A bus error skips the tile and, after
 *     repeated failures, disables the panel permanently for this run. It can
 *     never abort or fail a mining operation.
 *
 * OFF unless explicitly enabled, so a mining-only deployment never executes
 * any of it. See am01_panel_init().
 */

#ifndef AM01_PANEL_H_INCLUDED
#define AM01_PANEL_H_INCLUDED

#include <stdint.h>
#include "am01_gpio_bus.h"

/* Panel geometry, landscape. The ILI9341 is natively 240x320 portrait; the
 * init sequence sets MADCTL to rotate, because odo-ui draws 320x240. */
#define AM01_PANEL_W 320
#define AM01_PANEL_H 240

/* Damage granularity. 16x16 keeps the per-tile cost small enough to fit in a
 * slice budget even on a slow bus: 256 pixel writes. */
#define AM01_PANEL_TILE 16

/* MEASURED on hardware by am01_busbench, 2026-08-30, against FPGA v0x0105:
 *
 *     LCD_DATA write (16-bit)   20.0 us/op    ~50k ops/s
 *     STATUS read    (16-bit)   20.6 us/op    ~48k ops/s
 *
 * A tile is AM01_PANEL_TILE^2 pixels, one 16-bit write each, plus the column
 * and page address writes that precede it. 256 * 20.0us = 5.1ms.
 *
 * This is the quantum am01_panel_slice() works in: it will not stop part way
 * through a tile, so any budget you pass is rounded up to a multiple of this.
 * Sizing a budget below it does not make slices shorter, it just means every
 * slice pushes exactly one tile.
 *
 * The same measurement is why the panel is damage-tracked rather than
 * full-frame: a whole 320x240 screen is 76,800 writes = 1.54s, i.e. 0.65fps. */
#define AM01_PANEL_TILE_US 5120u

/*
 * Enable and initialise the panel.
 *
 * Does nothing and returns 0 (not an error) unless AM01_PANEL is set to a
 * non-zero value in the environment -- being off by default is deliberate,
 * so that a deployment which only cares about hashing cannot be affected by
 * a bug in here.
 *
 * The framebuffer device comes from AM01_PANEL_FB, default /dev/fb1. fb1
 * rather than fb0 because fb0 is the HDMI framebuffer and the console and
 * odo-ui already use it; the panel's surface is a separate vfb instance.
 *
 * Returns 0 if the panel is ready OR deliberately disabled, -1 only if it was
 * asked for and could not be brought up. Even then the caller should carry on
 * mining -- see am01_panel_slice(), which is a no-op once disabled.
 */
int am01_panel_init(am01_bus_t *bus);

/*
 * Push at most `budget_us` microseconds' worth of changed tiles.
 *
 * Call from the miner's idle path only. Returns the number of tiles pushed
 * (0 is normal and means nothing changed). Never returns an error: failures
 * are handled internally, because a display fault must not become a mining
 * fault.
 *
 * The budget is advisory in one direction only: a tile in progress is always
 * finished, so actual time may overrun by up to one tile. It is never
 * abandoned mid-transaction -- a partial SPI write would desynchronise the
 * panel's command stream.
 */
int am01_panel_slice(am01_bus_t *bus, unsigned budget_us);

/* Backlight off, panel to sleep, release the framebuffer mapping. Safe to
 * call when the panel was never enabled. */
void am01_panel_shutdown(am01_bus_t *bus);

/* Whether the panel is live. Useful for status output. */
int am01_panel_active(void);

#endif /* AM01_PANEL_H_INCLUDED */
