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
/* 5 address lines: GPIO16-19 plus GPIO24 as addr[4]. GPIO24 was already
 * wired to the FPGA but unused, so the register space went from 16 to 32
 * slots without new hardware. Requires wrapper VERSION >= 0x0103; against an
 * older bitstream addr[4] simply goes nowhere and the low 16 still work. */
#define NUM_ADDR_LINES 5
static const unsigned int ADDR_OFFSETS[NUM_ADDR_LINES] = { 16, 17, 18, 19, 24 };
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
    ADDR_TEMP      = 11,  /* wrapper VERSION >= 0x0102 */
    ADDR_VCCINT    = 12,
    ADDR_VCCAUX    = 13,
    ADDR_VCCBRAM   = 14,
    ADDR_FAN       = 15,
    /* Above 0x0F needs the 5th address line, so VERSION >= 0x0103. */
    ADDR_LCD_CMD   = 16,
    ADDR_LCD_DATA  = 17,
    ADDR_LCD_STAT  = 18,
    ADDR_LCD_CTRL  = 19,
    /* 8-bit, DC=1. RTL 5'h17 = 23. Present since v0x0104, unused until
     * 2026-08-30 -- see am01_bus_lcd_data8(). */
    ADDR_LCD_DATA8 = 23,
    ADDR_TOUCH_X   = 20,
    ADDR_TOUCH_Y   = 21,
    ADDR_TOUCH_STAT= 22,
};

/* Register-interface version that first exposed SEED_LO/SEED_HI. Older
 * bitstreams return 0 for unmapped addresses, which is indistinguishable from
 * a real seed of 0, so the version is checked before trusting the value. */
#define AM01_VERSION_WITH_SEED 0x0101

/* Register-interface version that first exposed the XADC temperature. */
#define AM01_VERSION_WITH_TEMP 0x0102

/* Version that widened gpio_addr to 5 bits and added the display block.
 * Below this the upper 16 registers are unreachable, because addr[4] is not
 * wired on the host side either. */
#define AM01_VERSION_WITH_LCD  0x0103

/* Generous, since this bus isn't timing-critical -- see ../README.md.
 * A real READY that never arrives (bad wiring, unprogrammed FPGA) fails
 * fast instead of hanging forever. */
#define READY_TIMEOUT_US 100000L /* 100ms */

struct am01_bus {
    struct gpiod_chip *chip;
    struct gpiod_line *data_lines[NUM_DATA_LINES];
    struct gpiod_line *addr_lines[NUM_ADDR_LINES];
    /* Bulk handles for the two wide groups. libgpiod's *_bulk calls move all
     * lines in one ioctl instead of one per line, which is the difference
     * between ~20 syscalls per 16-bit word and ~4. */
    struct gpiod_line_bulk data_bulk;
    struct gpiod_line_bulk addr_bulk;
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

    if (bus->data_is_output != -1)
        gpiod_line_release_bulk(&bus->data_bulk);

    int rc;
    if (output) {
        int defaults[NUM_DATA_LINES] = { 0 };
        rc = gpiod_line_request_bulk_output(&bus->data_bulk, CONSUMER, defaults);
    } else {
        rc = gpiod_line_request_bulk_input(&bus->data_bulk, CONSUMER);
    }
    if (rc < 0)
        return -1;

    bus->data_is_output = output;
    return 0;
}

static int drive_addr(am01_bus_t *bus, uint8_t addr)
{
    int v[NUM_ADDR_LINES];
    for (int i = 0; i < NUM_ADDR_LINES; i++)
        v[i] = (addr >> i) & 1;
    return gpiod_line_set_value_bulk(&bus->addr_bulk, v);
}

static int drive_data(am01_bus_t *bus, uint16_t data)
{
    int v[NUM_DATA_LINES];
    for (int i = 0; i < NUM_DATA_LINES; i++)
        v[i] = (data >> i) & 1;
    /* One ioctl for all 16 bits -- and they change simultaneously, which the
     * per-line version could not guarantee. The FPGA samples DATA on the WR_N
     * strobe, so a skewed bus was a latent setup-time hazard as well as slow. */
    return gpiod_line_set_value_bulk(&bus->data_bulk, v);
}

static int sample_data(am01_bus_t *bus, uint16_t *data_out)
{
    int v[NUM_DATA_LINES];
    if (gpiod_line_get_value_bulk(&bus->data_bulk, v) < 0)
        return -1;
    uint16_t w = 0;
    for (int i = 0; i < NUM_DATA_LINES; i++)
        w |= (uint16_t)(v[i] & 1) << i;
    /* Single ioctl, so all 16 bits are sampled at the same instant rather
     * than smeared across 16 syscalls while the FPGA holds them stable. */
    *data_out = w;
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
    /* Release the data bus BEFORE asserting RD_N.
     *
     * The wrapper's S_READ state asserts gpio_data_oe as soon as it sees RD_N
     * low, so the FPGA starts driving all 16 data lines immediately. If this
     * end is still configured as outputs -- which it is after any write, since
     * set_data_direction() is sticky -- both ends drive the bus at once. That
     * is a real short through the IOBs on both sides, not just a corrupt read:
     * it wastes power and can only ever return garbage.
     *
     * The first read after open() happened to work because the data lines had
     * not been requested yet, which is why this stayed hidden until a read
     * followed a write (exactly what am01_bus_test does: read STATUS, submit
     * 27 words, then read back). */
    if (set_data_direction(bus, 0) < 0) return -1;
    if (drive_addr(bus, addr) < 0) return -1;

    if (gpiod_line_set_value(bus->rd_n, 0) < 0) return -1;
    if (wait_ready(bus, 1) < 0) return -1;
    if (sample_data(bus, data_out) < 0) return -1;
    if (gpiod_line_set_value(bus->rd_n, 1) < 0) return -1;
    if (wait_ready(bus, 0) < 0) return -1;
    return 0;
}

/* Find the SoC's own GPIO controller by label rather than by number.
 *
 * gpiochip numbering is probe-order dependent: a CM4 also exposes a small
 * raspberrypi-exp-gpio expander, and either can end up as gpiochip0 depending
 * on kernel version. Hardcoding "gpiochip0" produced "failed to open
 * gpiochip0" on this kernel. The label is stable where the number is not.
 *
 * Also checks the line count: the bus needs offsets up to 24, and the
 * expander only has 8 lines, so a label match on the wrong chip would fail
 * later and more confusingly. */
static struct gpiod_chip *open_soc_gpiochip(void)
{
    struct gpiod_chip_iter *iter = gpiod_chip_iter_new();
    if (!iter)
        return NULL;

    struct gpiod_chip *chip, *found = NULL;
    gpiod_foreach_chip(iter, chip) {
        const char *label = gpiod_chip_label(chip);
        if (label && strncmp(label, "pinctrl-bcm", 11) == 0 &&
            gpiod_chip_num_lines(chip) > IRQ_OFFSET) {
            found = chip;
            break;      /* iterator will not close the one we keep */
        }
    }
    if (found)
        gpiod_chip_iter_free_noclose(iter);
    else
        gpiod_chip_iter_free(iter);
    return found;
}

am01_bus_t *am01_bus_open(const char *gpiochip_name)
{
    am01_bus_t *bus = calloc(1, sizeof(*bus));
    if (!bus)
        return NULL;
    bus->data_is_output = -1;

    /* NULL or "auto" means find it ourselves. An explicit name still wins,
     * so the test tool can override when debugging. */
    if (!gpiochip_name || strcmp(gpiochip_name, "auto") == 0)
        bus->chip = open_soc_gpiochip();
    else
        bus->chip = gpiod_chip_open_by_name(gpiochip_name);
    if (!bus->chip)
        goto fail;

    gpiod_line_bulk_init(&bus->data_bulk);
    for (int i = 0; i < NUM_DATA_LINES; i++) {
        bus->data_lines[i] = gpiod_chip_get_line(bus->chip, DATA_OFFSETS[i]);
        if (!bus->data_lines[i])
            goto fail;
        gpiod_line_bulk_add(&bus->data_bulk, bus->data_lines[i]);
    }

    gpiod_line_bulk_init(&bus->addr_bulk);
    for (int i = 0; i < NUM_ADDR_LINES; i++) {
        bus->addr_lines[i] = gpiod_chip_get_line(bus->chip, ADDR_OFFSETS[i]);
        if (!bus->addr_lines[i])
            goto fail;
        gpiod_line_bulk_add(&bus->addr_bulk, bus->addr_lines[i]);
    }
    {
        int defaults[NUM_ADDR_LINES] = { 0 };
        if (gpiod_line_request_bulk_output(&bus->addr_bulk, CONSUMER, defaults) < 0)
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

int am01_bus_read_temp(am01_bus_t *bus, double *celsius_out)
{
    uint16_t ver, raw;

    if (reg_read16(bus, ADDR_VERSION, &ver) < 0)
        return -1;
    if (ver < AM01_VERSION_WITH_TEMP) {
        errno = ENOTSUP;
        return -1;
    }
    if (reg_read16(bus, ADDR_TEMP, &raw) < 0)
        return -1;

    /* XADC returns a 12-bit code in the top bits. The transfer function is
     * from Xilinx UG480: degC = code * 503.975 / 4096 - 273.15. A code of 0
     * means no conversion has completed yet, which would read as -273C. */
    if (raw == 0) {
        errno = EAGAIN;
        return -1;
    }
    *celsius_out = ((double)(raw >> 4) * 503.975 / 4096.0) - 273.15;
    return 0;
}

/* ---- display / fan / touch ------------------------------------------- */

static int need_version(am01_bus_t *bus, uint16_t min)
{
    uint16_t ver;
    if (reg_read16(bus, ADDR_VERSION, &ver) < 0)
        return -1;
    if (ver < min) {
        errno = ENOTSUP;
        return -1;
    }
    return 0;
}

int am01_bus_lcd_cmd(am01_bus_t *bus, uint8_t cmd)
{
    if (need_version(bus, AM01_VERSION_WITH_LCD) < 0)
        return -1;
    return reg_write16(bus, ADDR_LCD_CMD, cmd);
}

int am01_bus_lcd_data(am01_bus_t *bus, uint16_t data)
{
    /* No version check on the hot path: callers do one am01_bus_lcd_cmd()
     * first, which checks. Re-reading VERSION per pixel would double the
     * traffic on the one path where throughput actually matters. */
    return reg_write16(bus, ADDR_LCD_DATA, data);
}

/* ONE byte, DC=1 -- for command parameters.
 *
 * Binds ADDR_LCD_DATA8, which the RTL has provided since v0x0104 and which no
 * software ever called. Until now a one-byte parameter was sent through the
 * 16-bit ADDR_LCD_DATA as `value << 8`, putting a surplus 0x00 on the wire
 * after every parameter.
 *
 * am01_panel.c justified that by saying the ILI9341 ignores parameters beyond
 * a command's declared count. True of single-parameter commands, and FALSE of
 * CASET/PASET (0x2A/0x2B), which take four each: eight bytes arrive, the panel
 * keeps the first four, and the address window becomes
 * [x0_hi, 0x00, x0_lo, 0x00]. Every pixel then lands outside any valid window
 * -- exactly the lit-but-blank panel the board showed on 2026-08-30. */
int am01_bus_lcd_data8(am01_bus_t *bus, uint8_t data)
{
    return reg_write16(bus, ADDR_LCD_DATA8, (uint16_t)data);
}

int am01_bus_lcd_busy(am01_bus_t *bus, int *busy_out)
{
    uint16_t v;
    if (reg_read16(bus, ADDR_LCD_STAT, &v) < 0)
        return -1;
    *busy_out = (v & 1);
    return 0;
}

int am01_bus_lcd_ctrl(am01_bus_t *bus, int reset_n, int backlight)
{
    if (need_version(bus, AM01_VERSION_WITH_LCD) < 0)
        return -1;
    return reg_write16(bus, ADDR_LCD_CTRL,
                       (uint16_t)((reset_n ? 1u : 0u) | (backlight ? 2u : 0u)));
}

int am01_bus_read_touch(am01_bus_t *bus, uint16_t *x, uint16_t *y, int *pressed)
{
    uint16_t sx, sy, st;
    if (need_version(bus, AM01_VERSION_WITH_LCD) < 0)
        return -1;
    if (reg_read16(bus, ADDR_TOUCH_X, &sx) < 0) return -1;
    if (reg_read16(bus, ADDR_TOUCH_Y, &sy) < 0) return -1;
    if (reg_read16(bus, ADDR_TOUCH_STAT, &st) < 0) return -1;
    if (x) *x = sx & 0x0FFF;
    if (y) *y = sy & 0x0FFF;
    if (pressed) *pressed = st & 1;
    return 0;
}

int am01_bus_fan(am01_bus_t *bus, int set_floor, uint8_t floor,
                 uint8_t *duty_out, uint8_t *tach_hz_out)
{
    if (need_version(bus, AM01_VERSION_WITH_TEMP) < 0)
        return -1;
    if (set_floor && reg_write16(bus, ADDR_FAN, floor) < 0)
        return -1;
    uint16_t v;
    if (reg_read16(bus, ADDR_FAN, &v) < 0)
        return -1;
    if (duty_out)    *duty_out    = (uint8_t)(v & 0xFF);
    if (tach_hz_out) *tach_hz_out = (uint8_t)(v >> 8);
    return 0;
}

int am01_bus_read_rails(am01_bus_t *bus, double *vccint, double *vccaux,
                        double *vccbram)
{
    uint16_t a, b, c;
    if (need_version(bus, AM01_VERSION_WITH_TEMP) < 0)
        return -1;
    if (reg_read16(bus, ADDR_VCCINT,  &a) < 0) return -1;
    if (reg_read16(bus, ADDR_VCCAUX,  &b) < 0) return -1;
    if (reg_read16(bus, ADDR_VCCBRAM, &c) < 0) return -1;
    /* XADC supply channels: volts = (code >> 4) * 3.0 / 4096  (UG480). */
    if (vccint)  *vccint  = (double)(a >> 4) * 3.0 / 4096.0;
    if (vccaux)  *vccaux  = (double)(b >> 4) * 3.0 / 4096.0;
    if (vccbram) *vccbram = (double)(c >> 4) * 3.0 / 4096.0;
    return 0;
}

/* FPGA versions at or below this arm start_hash only on every OTHER dispatch.
 *
 * target_word_cnt_h in the wrapper was reg [3:0] while being compared against
 * 7, so it wrapped at 16 instead of 8 and nothing reset it between jobs.
 * Dispatch 1 walks counts 0..7 and arms on the 8th word; dispatch 2 walks
 * 8..15, never equals 7, and never arms. The core hashed on alternate jobs and
 * sat idle in between -- and on a dispatch that did not arm, the found-latch
 * still held the PREVIOUS job's nonce, so the host read a stale value and
 * scored it against the new header. That is the whole of "found=10 shares=0
 * stale=10".
 *
 * Fixed in the RTL at 0x0106 (3-bit counter). This sends the target block
 * TWICE on older bitstreams, which covers both parities and arms reliably --
 * measured: 6 valid nonces out of 6 against a 1-in-256 target, where the same
 * test single-dispatching alternated between one find and none.
 *
 * The extra 8 writes cost ~160us on a job change and nothing in steady state.
 * Remove this once no 0x0105-or-earlier bitstream is in service. */
#define AM01_LAST_ALT_ARM_VERSION 0x0105u

int am01_bus_submit_work(am01_bus_t *bus, const uint32_t header[19], const uint32_t target[8])
{
    for (int i = 0; i < 19; i++)
        if (am01_bus_write_header_word(bus, header[i]) < 0)
            return -1;

    uint16_t ver = 0;
    int reps = 1;
    if (am01_bus_read_version(bus, &ver) == 0 && ver <= AM01_LAST_ALT_ARM_VERSION)
        reps = 2;

    for (int r = 0; r < reps; r++)
        for (int i = 0; i < 8; i++)
            if (am01_bus_write_target_word(bus, target[i]) < 0)
                return -1;

    return 0; /* the arming target-word write sets start_hash on the FPGA side */
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
