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
 * Bit-banged implementation of am01_gpio_bus.h using libgpiod (v1 C API).
 * Mirrors the 4-phase interlocked handshake implemented in hardware by
 * ../hdl/odocrypt_gpio_wrapper.v's bus-side state machine -- read that
 * file's S_WRITE/S_READ states alongside this one if something's unclear.
 *
 * This is deliberately the *simple* path (one gpiod_line_set/get_value
 * syscall per bit, per beat) rather than the BCM2711 SMI peripheral the
 * QMTECH manual mentions as a faster option. Given this workload's tiny
 * data volume (27 words per work item, one nonce read per solve) the
 * syscall overhead here is very unlikely to matter -- revisit only if
 * profiling says otherwise.
 *
 * STATUS: reference skeleton, not run against real hardware or even
 * compiled against a real libgpiod as part of this repo.
 */
#include "am01_gpio_bus.h"

#include <gpiod.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>

#define CONSUMER "am01-gpio-bus"

/* GPIO offsets, per ../README.md's pinout table (GPIO0..27 on the CM4
 * socket). See the header's warning: this assumes gpiochip line offset
 * == BCM GPIO number -- verify with `gpioinfo` before trusting it. */
#define NUM_DATA_LINES 16
static const unsigned int DATA_OFFSETS[NUM_DATA_LINES] = {
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
};
#define NUM_ADDR_LINES 4
static const unsigned int ADDR_OFFSETS[NUM_ADDR_LINES] = { 16, 17, 18, 19 };
#define WR_N_OFFSET   20
#define RD_N_OFFSET   21
#define READY_OFFSET  22
#define IRQ_OFFSET    23

/* Register addresses -- must match ../hdl/odocrypt_gpio_wrapper.v's
 * ADDR_* localparams exactly. */
enum {
    ADDR_VERSION   = 0,
    ADDR_CTRL      = 1,
    ADDR_STATUS    = 2,
    ADDR_NONCE_LO  = 3,
    ADDR_NONCE_HI  = 4,
    ADDR_HEADER_LO = 5,
    ADDR_HEADER_HI = 6,
    ADDR_TARGET_LO = 7,
    ADDR_TARGET_HI = 8,
    ADDR_SEED_LO   = 9,   /* wrapper VERSION >= 0x0101 */
    ADDR_SEED_HI   = 10,
};

/* Register-interface version that first exposed SEED_LO/SEED_HI. Older
 * bitstreams return 0 for unmapped addresses, which is indistinguishable from
 * a real seed of 0, so the version is checked before trusting the value. */
#define AM01_VERSION_WITH_SEED 0x0101

/* Generous, since this bus isn't timing-critical -- see ../README.md.
 * A real READY that never arrives (bad wiring, unprogrammed FPGA) fails
 * fast instead of hanging forever. */
#define READY_TIMEOUT_US 100000L /* 100ms */

struct am01_bus {
    struct gpiod_chip *chip;
    struct gpiod_line *data_lines[NUM_DATA_LINES];
    struct gpiod_line *addr_lines[NUM_ADDR_LINES];
    struct gpiod_line *wr_n;
    struct gpiod_line *rd_n;
    struct gpiod_line *ready;
    struct gpiod_line *irq;
    int data_is_output; /* -1 = unknown/unrequested, 0 = input, 1 = output */
};

static long elapsed_us(const struct timespec *start, const struct timespec *now)
{
    return (now->tv_sec - start->tv_sec) * 1000000L +
           (now->tv_nsec - start->tv_nsec) / 1000L;
}

static int wait_ready(am01_bus_t *bus, int level)
{
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (;;) {
        int v = gpiod_line_get_value(bus->ready);
        if (v < 0)
            return -1;
        if (v == level)
            return 0;
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (elapsed_us(&start, &now) > READY_TIMEOUT_US) {
            errno = ETIMEDOUT;
            return -1;
        }
    }
}

/* The DATA lines are bidirectional on the FPGA side; libgpiod fixes a
 * line's direction for the lifetime of its request, so switching means
 * release + re-request. Cheap enough at this bus's traffic volume. */
static int set_data_direction(am01_bus_t *bus, int output)
{
    if (bus->data_is_output == output)
        return 0;

    for (int i = 0; i < NUM_DATA_LINES; i++) {
        gpiod_line_release(bus->data_lines[i]);
        int rc = output
            ? gpiod_line_request_output(bus->data_lines[i], CONSUMER, 0)
            : gpiod_line_request_input(bus->data_lines[i], CONSUMER);
        if (rc < 0)
            return -1;
    }
    bus->data_is_output = output;
    return 0;
}

static int drive_addr(am01_bus_t *bus, uint8_t addr)
{
    for (int i = 0; i < NUM_ADDR_LINES; i++)
        if (gpiod_line_set_value(bus->addr_lines[i], (addr >> i) & 1) < 0)
            return -1;
    return 0;
}

static int drive_data(am01_bus_t *bus, uint16_t data)
{
    for (int i = 0; i < NUM_DATA_LINES; i++)
        if (gpiod_line_set_value(bus->data_lines[i], (data >> i) & 1) < 0)
            return -1;
    return 0;
}

static int sample_data(am01_bus_t *bus, uint16_t *data_out)
{
    uint16_t v = 0;
    for (int i = 0; i < NUM_DATA_LINES; i++) {
        int bit = gpiod_line_get_value(bus->data_lines[i]);
        if (bit < 0)
            return -1;
        v |= (uint16_t)(bit & 1) << i;
    }
    *data_out = v;
    return 0;
}

/* 4-phase interlocked write -- mirrors odocrypt_gpio_wrapper.v's
 * S_WRITE state: drive ADDR+DATA, assert WR_N, wait READY, release
 * WR_N, wait READY to drop. */
static int reg_write16(am01_bus_t *bus, uint8_t addr, uint16_t data)
{
    if (set_data_direction(bus, 1) < 0) return -1;
    if (drive_addr(bus, addr) < 0) return -1;
    if (drive_data(bus, data) < 0) return -1;

    if (gpiod_line_set_value(bus->wr_n, 0) < 0) return -1;
    if (wait_ready(bus, 1) < 0) return -1;
    if (gpiod_line_set_value(bus->wr_n, 1) < 0) return -1;
    if (wait_ready(bus, 0) < 0) return -1;
    return 0;
}

/* 4-phase interlocked read -- mirrors odocrypt_gpio_wrapper.v's S_READ
 * state: drive ADDR, assert RD_N, wait READY, sample DATA, release
 * RD_N, wait READY to drop. */
static int reg_read16(am01_bus_t *bus, uint8_t addr, uint16_t *data_out)
{
    if (drive_addr(bus, addr) < 0) return -1;

    if (gpiod_line_set_value(bus->rd_n, 0) < 0) return -1;
    if (wait_ready(bus, 1) < 0) return -1;
    if (set_data_direction(bus, 0) < 0) return -1;
    if (sample_data(bus, data_out) < 0) return -1;
    if (gpiod_line_set_value(bus->rd_n, 1) < 0) return -1;
    if (wait_ready(bus, 0) < 0) return -1;
    return 0;
}

am01_bus_t *am01_bus_open(const char *gpiochip_name)
{
    am01_bus_t *bus = calloc(1, sizeof(*bus));
    if (!bus)
        return NULL;
    bus->data_is_output = -1;

    bus->chip = gpiod_chip_open_by_name(gpiochip_name);
    if (!bus->chip)
        goto fail;

    for (int i = 0; i < NUM_DATA_LINES; i++) {
        bus->data_lines[i] = gpiod_chip_get_line(bus->chip, DATA_OFFSETS[i]);
        if (!bus->data_lines[i])
            goto fail;
    }
    for (int i = 0; i < NUM_ADDR_LINES; i++) {
        bus->addr_lines[i] = gpiod_chip_get_line(bus->chip, ADDR_OFFSETS[i]);
        if (!bus->addr_lines[i])
            goto fail;
        if (gpiod_line_request_output(bus->addr_lines[i], CONSUMER, 0) < 0)
            goto fail;
    }

    bus->wr_n  = gpiod_chip_get_line(bus->chip, WR_N_OFFSET);
    bus->rd_n  = gpiod_chip_get_line(bus->chip, RD_N_OFFSET);
    bus->ready = gpiod_chip_get_line(bus->chip, READY_OFFSET);
    bus->irq   = gpiod_chip_get_line(bus->chip, IRQ_OFFSET);
    if (!bus->wr_n || !bus->rd_n || !bus->ready || !bus->irq)
        goto fail;

    /* WR_N/RD_N idle high (deasserted). */
    if (gpiod_line_request_output(bus->wr_n, CONSUMER, 1) < 0) goto fail;
    if (gpiod_line_request_output(bus->rd_n, CONSUMER, 1) < 0) goto fail;
    if (gpiod_line_request_input(bus->ready, CONSUMER) < 0) goto fail;
    if (gpiod_line_request_both_edges_events(bus->irq, CONSUMER) < 0) goto fail;

    if (set_data_direction(bus, 1) < 0) /* default DATA to output, idle 0 */
        goto fail;

    return bus;

fail:
    am01_bus_close(bus);
    return NULL;
}

void am01_bus_close(am01_bus_t *bus)
{
    if (!bus)
        return;
    if (bus->chip)
        gpiod_chip_close(bus->chip); /* releases every line opened from it */
    free(bus);
}

int am01_bus_write_ctrl(am01_bus_t *bus, uint16_t ctrl_bits)
{
    return reg_write16(bus, ADDR_CTRL, ctrl_bits);
}

int am01_bus_read_status(am01_bus_t *bus, uint16_t *status_out)
{
    return reg_read16(bus, ADDR_STATUS, status_out);
}

int am01_bus_write_header_word(am01_bus_t *bus, uint32_t word)
{
    if (reg_write16(bus, ADDR_HEADER_LO, (uint16_t)(word & 0xFFFF)) < 0)
        return -1;
    return reg_write16(bus, ADDR_HEADER_HI, (uint16_t)((word >> 16) & 0xFFFF));
}

int am01_bus_write_target_word(am01_bus_t *bus, uint32_t word)
{
    if (reg_write16(bus, ADDR_TARGET_LO, (uint16_t)(word & 0xFFFF)) < 0)
        return -1;
    return reg_write16(bus, ADDR_TARGET_HI, (uint16_t)((word >> 16) & 0xFFFF));
}

int am01_bus_read_nonce(am01_bus_t *bus, uint32_t *nonce_out)
{
    uint16_t lo, hi;
    if (reg_read16(bus, ADDR_NONCE_LO, &lo) < 0)
        return -1;
    if (reg_read16(bus, ADDR_NONCE_HI, &hi) < 0) /* clears NONCE_VALID/IRQ */
        return -1;
    *nonce_out = ((uint32_t)hi << 16) | lo;
    return 0;
}

int am01_bus_read_version(am01_bus_t *bus, uint16_t *version_out)
{
    return reg_read16(bus, ADDR_VERSION, version_out);
}

int am01_bus_read_seed(am01_bus_t *bus, uint32_t *seed_out)
{
    uint16_t ver, lo, hi;

    /* Unmapped addresses read back as 0 on older bitstreams, which is
     * indistinguishable from a genuine seed. Gate on the interface version so
     * the caller learns "unknown" instead of being told the epoch is 0. */
    if (reg_read16(bus, ADDR_VERSION, &ver) < 0)
        return -1;
    if (ver < AM01_VERSION_WITH_SEED) {
        errno = ENOTSUP;
        return -1;
    }

    if (reg_read16(bus, ADDR_SEED_LO, &lo) < 0)
        return -1;
    if (reg_read16(bus, ADDR_SEED_HI, &hi) < 0)
        return -1;
    *seed_out = ((uint32_t)hi << 16) | lo;
    return 0;
}

int am01_bus_submit_work(am01_bus_t *bus, const uint32_t header[19], const uint32_t target[8])
{
    for (int i = 0; i < 19; i++)
        if (am01_bus_write_header_word(bus, header[i]) < 0)
            return -1;
    for (int i = 0; i < 8; i++)
        if (am01_bus_write_target_word(bus, target[i]) < 0)
            return -1;
    return 0; /* the 8th target word write arms start_hash on the FPGA side */
}

int am01_bus_wait_irq(am01_bus_t *bus, int timeout_ms)
{
    struct timespec ts = { timeout_ms / 1000, (long)(timeout_ms % 1000) * 1000000L };
    int rc = gpiod_line_event_wait(bus->irq, &ts);
    if (rc < 0)
        return -1;
    if (rc == 0) {
        errno = ETIMEDOUT;
        return -1;
    }
    struct gpiod_line_event ev;
    return gpiod_line_event_read(bus->irq, &ev);
}
