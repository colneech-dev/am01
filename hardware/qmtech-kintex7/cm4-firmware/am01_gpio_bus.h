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

/* Reads the OdoCrypt epoch seed the loaded bitstream was built for, so the
 * daemon can tell a stale bitstream from a current one instead of mining
 * rejects silently. Returns 0 on success.
 *
 * Returns -1 with errno == ENOTSUP against a bitstream whose register
 * interface predates SEED_LO/SEED_HI (VERSION < 0x0101). Treat that as
 * "epoch unknown" -- it is NOT the same as a seed of 0. */
int am01_bus_read_seed(am01_bus_t *bus, uint32_t *seed_out);

/* Blocks (with a timeout) on the IRQ line's edge event, signaling a new
 * golden nonce is ready. Returns 0 on an edge seen, -1 on timeout/error
 * (errno == ETIMEDOUT on timeout). Follow with am01_bus_read_nonce(). */
int am01_bus_wait_irq(am01_bus_t *bus, int timeout_ms);

#ifdef __cplusplus
}
#endif

#endif /* AM01_GPIO_BUS_H */
