/*
 * AtomMiner AM01 -- QMTECH Kintex-7 + Raspberry Pi CM4 variant, design proposal
 *
 * Copyright 2015-2022 AtomMiner <atom@atomminer.com>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation; either version 3 of the License, or (at your option)
 * any later version. If not, see <http://www.gnu.org/licenses/>.
 *
 * -------------------------------------------------------------------------
 * Userspace driver for the GPIO parallel bus implemented by
 * ../hdl/odocrypt_gpio_wrapper.v. See ../README.md for the protocol and
 * pinout this talks to.
 *
 * STATUS: reference skeleton, not run against real hardware -- see
 * ../README.md's "what's still needed" list.
 */
#ifndef AM01_GPIO_BUS_H
#define AM01_GPIO_BUS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct am01_bus am01_bus_t;

/* Opens gpiochip_name (e.g. "gpiochip0") and requests the 24 lines this
 * bus uses. Returns NULL on failure (check errno / stderr).
 *
 * NOTE: this assumes the gpiochip line offset for each signal equals the
 * "GPIOn" number silkscreened on the QMTECH board / listed in its manual
 * (i.e. offset == BCM GPIO number). That mapping is generally true on
 * mainline Raspberry Pi kernels but isn't guaranteed -- run `gpioinfo`
 * against your actual image before trusting it, and adjust the offset
 * tables at the top of am01_gpio_bus.c if it doesn't match. */
am01_bus_t *am01_bus_open(const char *gpiochip_name);
void        am01_bus_close(am01_bus_t *bus);

/* CTRL register bits (see ../README.md's register map). */
#define AM01_CTRL_SOFT_RST   (1u << 0)
#define AM01_CTRL_HOST_BREAK (1u << 1)

/* STATUS register bits. */
#define AM01_STATUS_HASH_ACTIVE (1u << 0)
#define AM01_STATUS_NONCE_VALID (1u << 1)

int am01_bus_write_ctrl(am01_bus_t *bus, uint16_t ctrl_bits);
int am01_bus_read_status(am01_bus_t *bus, uint16_t *status_out);

/* Write one 32-bit header/target word (two 16-bit beats each, LO then
 * HI -- the HI beat is what commits the word into odo_block_data on the
 * FPGA side). Call write_header_word 19 times then write_target_word 8
 * times to submit one full work item -- the 8th target word arms
 * start_hash on the FPGA. am01_bus_submit_work() does this for you. */
int am01_bus_write_header_word(am01_bus_t *bus, uint32_t word);
int am01_bus_write_target_word(am01_bus_t *bus, uint32_t word);
int am01_bus_submit_work(am01_bus_t *bus, const uint32_t header[19], const uint32_t target[8]);

/* Reads the golden nonce (LO then HI beat). Reading the HI beat clears
 * STATUS.NONCE_VALID and deasserts IRQ on the FPGA side. */
int am01_bus_read_nonce(am01_bus_t *bus, uint32_t *nonce_out);

/* Reads the wrapper's register-interface version (0x0101 = SEED registers
 * present). Returns 0 on success. */
int am01_bus_read_version(am01_bus_t *bus, uint16_t *version_out);

/* Reads the OdoCrypt epoch seed the loaded bitstream was built for, so the
 * daemon can tell a stale bitstream from a current one instead of mining
 * rejects silently. Returns 0 on success.
 *
 * Returns -1 with errno == ENOTSUP against a bitstream whose register
 * interface predates SEED_LO/SEED_HI (VERSION < 0x0101). Treat that as
 * "epoch unknown" -- it is NOT the same as a seed of 0. */
int am01_bus_read_seed(am01_bus_t *bus, uint32_t *seed_out);

/* Reads the FPGA's on-die temperature via XADC, in degrees C. Returns 0 on
 * success.
 *
 * -1 / ENOTSUP against a bitstream older than VERSION 0x0102.
 * -1 / EAGAIN if no conversion has completed yet (raw code still 0), which
 * is normal for the first few microseconds after configuration.
 *
 * This is the die temperature, which is the number that matters: the design
 * free-runs at full power from the moment it configures, and a heatsink
 * probe would lag it badly. There is nowhere on this board to attach an
 * external sensor in any case -- every CM4 GPIO goes to FPGA fabric. */
int am01_bus_read_temp(am01_bus_t *bus, double *celsius_out);

/* ---- ILI9341 display, XPT2046 touch, fan, supply rails ----------------
 *
 * All require wrapper VERSION >= 0x0103 (the display/touch ones) or 0x0102
 * (fan, rails); they return -1/ENOTSUP otherwise rather than writing to a
 * register that does not exist.
 *
 * The FPGA is only a transport for the panel: the ILI9341 holds the image in
 * its own GRAM, so there is no framebuffer on either side and pixels are
 * written straight through. lcd_data() skips the version check because it is
 * the one path where throughput matters. */
int am01_bus_lcd_cmd(am01_bus_t *bus, uint8_t cmd);
int am01_bus_lcd_data(am01_bus_t *bus, uint16_t data);
int am01_bus_lcd_data8(am01_bus_t *bus, uint8_t data);
int am01_bus_lcd_busy(am01_bus_t *bus, int *busy_out);
int am01_bus_lcd_ctrl(am01_bus_t *bus, int reset_n, int backlight);
int am01_bus_read_touch(am01_bus_t *bus, uint16_t *x, uint16_t *y, int *pressed);

/* Fan: optionally set a duty FLOOR (the fabric's temperature curve still
 * applies above it, so software can raise cooling but never disable it), and
 * read back current duty plus tach pulses/sec. A tach of 0 with non-zero duty
 * means a stalled or disconnected fan. */
int am01_bus_fan(am01_bus_t *bus, int set_floor, uint8_t floor,
                 uint8_t *duty_out, uint8_t *tach_hz_out);

/* XADC supply rails in volts. VCCINT is the one worth watching: ~12A at 1.0V
 * through the MP8712, and a sagging core rail yields wrong hashes while the
 * board still looks healthy. */
int am01_bus_read_rails(am01_bus_t *bus, double *vccint, double *vccaux,
                        double *vccbram);

/* Blocks (with a timeout) on the IRQ line's edge event, signaling a new
 * golden nonce is ready. Returns 0 on an edge seen, -1 on timeout/error
 * (errno == ETIMEDOUT on timeout). Follow with am01_bus_read_nonce(). */
int am01_bus_wait_irq(am01_bus_t *bus, int timeout_ms);

/* Raw access to any register in the 5-bit address space, for am01_reg and for
 * bringing up a register the typed accessors above do not cover yet.
 *
 * Deliberately unvalidated: no version check, no interpretation. That is the
 * point -- when a register is not behaving, a typed accessor that refuses to
 * read it because the VERSION looks wrong is exactly the wrong tool. Use the
 * typed accessors everywhere else.
 *
 * CAUTION: reading ADDR_NONCE_HI (0x04) has the side effect of clearing
 * NONCE_VALID, and on v2.0+ of acknowledging the found-FIFO handoff. */
int am01_bus_read_reg(am01_bus_t *bus, uint8_t addr, uint16_t *value_out);
int am01_bus_write_reg(am01_bus_t *bus, uint8_t addr, uint16_t value);

#ifdef __cplusplus
}
#endif

#endif /* AM01_GPIO_BUS_H */
