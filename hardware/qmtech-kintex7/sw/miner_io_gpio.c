/*
 * AM01 + CM4 — mining daemon I/O layer over GPIO bus (implementation)
 *
 * Drop-in replacement for miner_io_pipe.c (Avalon-MM). Exposes the exact same
 * function names and semantics, but uses the am01_gpio_bus transport layer.
 * The daemon (miner_pipe.c) needs zero changes; just compile with this instead.
 */

#define _POSIX_C_SOURCE 200809L

#include "miner_io_pipe.h"
#include "am01_gpio_bus.h"

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>

/* Reported when the bitstream's epoch seed cannot be read -- a register
 * interface older than v1.1, or a bus error. Deliberately 0 rather than a
 * distinctive sentinel: the daemon's staleness check is `job epoch != seed`,
 * so this trips on every job and logs "bitstream epoch 0", which is the
 * honest answer when the epoch is genuinely unknown. Anything else would
 * read like a real epoch. */
#define MINER_IO_SEED_UNKNOWN 0u

/* =====================================================================
 * Global state: single GPIO bus instance for the entire daemon.
 * ===================================================================== */
static am01_bus_t *g_bus = NULL;
static uint32_t    g_version = 0;
static uint32_t    g_seed = 0;
static int         g_initialized = 0;

/* =====================================================================
 * Public API implementation — identical signatures to miner_io_pipe.c
 * ===================================================================== */

int miner_io_pipe_init(void)
{
    if (g_initialized)
        return 0;   /* Already open */

    /* NULL -> locate the SoC GPIO controller by label. gpiochip numbering
     * is probe-order dependent and "gpiochip0" was not it on this kernel.
     * AM01_GPIOCHIP overrides, for debugging. */
    g_bus = am01_bus_open(getenv("AM01_GPIOCHIP"));
    if (!g_bus) {
        fprintf(stderr, "miner_io_pipe_init: am01_bus_open failed\n");
        return -1;
    }

    /* Both are bitstream constants, read once at startup.
     *
     * The seed matters: the daemon compares it against each job's epoch to
     * decide whether the loaded bitstream still implements the algorithm the
     * chain is using. This used to be hardcoded to 0, which made that check
     * fire on every job and rendered its warning meaningless. */
    uint16_t raw_ver = 0;
    if (am01_bus_read_version(g_bus, &raw_ver) == 0) {
        /* Wrapper reports 16-bit BCD-ish (0x0101 = v1.1); the daemon's API is
         * 32-bit major<<16 | minor. */
        g_version = ((uint32_t)(raw_ver >> 8) << 16) | (raw_ver & 0xFF);
    } else {
        fprintf(stderr, "miner_io_pipe_init: failed to read VERSION: %s\n",
                strerror(errno));
        g_version = 0;
    }

    /* RESYNC THE FOUND PATH BEFORE MINING, and report what we are clearing.
     *
     * On 2026-09-01 a deploy left the FPGA wedged: the previous process was
     * killed between a nonce handover and its ack, which latched found_path's
     * `busy` with no ack ever coming. Every subsequent find was then dropped.
     * It survived restarts -- nothing host-side could clear it -- and needed a
     * JTAG reload, costing an hour of mining.
     *
     * A saturated lost counter here is the fingerprint of exactly that, so it
     * is READ FIRST and reported loudly. Reading before resetting matters:
     * the reset clears it, and a number nobody saw is a number that may as
     * well not exist -- which is how the outage went undiagnosed for as long
     * as it did.
     *
     * Needs VERSION >= 0x0203 to actually reach found_path; older bitstreams
     * accept the write and simply do less, which is harmless. */
    uint8_t lost0 = 0, depth0 = 0;
    if (am01_bus_read_fifo_stat(g_bus, &lost0, &depth0) == 0 && lost0 > 0) {
        fprintf(stderr,
                "miner_io_pipe_init: found-FIFO reports %u lost find(s)%s, "
                "depth %u -- the previous run left finds undrained\n",
                lost0, lost0 == 0xFF ? " (SATURATED)" : "", depth0);
        if (lost0 == 0xFF)
            fprintf(stderr,
                    "miner_io_pipe_init: a saturated counter means the found "
                    "path was STALLED, not merely busy\n");
    }
    if (am01_bus_write_ctrl(g_bus, 0x0001) < 0)   /* CTRL[0] = OP_SOFT_RESET */
        fprintf(stderr, "miner_io_pipe_init: soft reset failed: %s\n",
                strerror(errno));

    if (am01_bus_read_seed(g_bus, &g_seed) < 0) {
        g_seed = MINER_IO_SEED_UNKNOWN;
        if (errno == ENOTSUP)
            fprintf(stderr, "miner_io_pipe_init: bitstream predates the SEED "
                            "register; epoch staleness cannot be detected\n");
        else
            fprintf(stderr, "miner_io_pipe_init: failed to read epoch seed: %s\n",
                    strerror(errno));
    } else {
        fprintf(stderr, "miner_io_pipe_init: bitstream epoch seed %u\n",
                (unsigned)g_seed);
    }

    g_initialized = 1;

    return 0;
}

void miner_io_pipe_shutdown(void)
{
    if (g_bus) {
        am01_bus_close(g_bus);
        g_bus = NULL;
    }
    g_initialized = 0;
}

uint32_t miner_io_pipe_version(void)
{
    return g_version;
}

am01_bus_t *miner_io_gpio_bus(void)
{
    return g_bus;
}

uint32_t miner_io_pipe_seed(void)
{
    return g_seed;
}

int miner_io_pipe_dispatch(const uint8_t header[80], const uint8_t target[32])
{
    if (!g_bus)
        return -1;

    /* Parse header and target as little-endian 32-bit words. */
    uint32_t header_words[19];
    uint32_t target_words[8];

    for (int i = 0; i < 19; i++) {
        const uint8_t *p = &header[i * 4];
        header_words[i] = (uint32_t)p[0]
                        | ((uint32_t)p[1] << 8)
                        | ((uint32_t)p[2] << 16)
                        | ((uint32_t)p[3] << 24);
    }

    for (int i = 0; i < 8; i++) {
        const uint8_t *p = &target[i * 4];
        target_words[i] = (uint32_t)p[0]
                        | ((uint32_t)p[1] << 8)
                        | ((uint32_t)p[2] << 16)
                        | ((uint32_t)p[3] << 24);
    }

    /* am01_bus_submit_work() sends all 19 header words + 8 target words
     * over the GPIO bus (two 16-bit beats per 32-bit word). */
    return am01_bus_submit_work(g_bus, header_words, target_words);
}

int miner_io_pipe_poll(uint32_t *out_nonce)
{
    if (!g_bus)
        return -1;

    /* Return values match miner_io_pipe.c semantics:
     *   0 = nonce was read
     *   1 = no nonce pending
     *  -1 = error
     *
     * STATUS must be checked first. Reading NONCE_HI is what clears
     * NONCE_VALID and drops the IRQ on the FPGA side, so an unconditional
     * read both invents a nonce when none is pending and consumes the flag.
     * This function used to always return 0, which left the daemon
     * validating a garbage nonce on every pass of its loop. */
    uint16_t status = 0;
    if (am01_bus_read_status(g_bus, &status) < 0)
        return -1;

    if (!(status & AM01_STATUS_NONCE_VALID))
        return 1;   /* nothing pending -- do NOT touch NONCE_HI */

    uint32_t nonce = 0;
    if (am01_bus_read_nonce(g_bus, &nonce) < 0)
        return -1;

    if (out_nonce)
        *out_nonce = nonce;
    return 0;
}

int miner_io_pipe_wait(int timeout_ms)
{
    if (!g_bus)
        return -1;

    /* GPIO23 is the FPGA's nonce-ready IRQ, requested for both-edge events in
     * am01_bus_open(), so block on the edge rather than spinning. An earlier
     * version slept 5ms and always claimed "timeout", on the mistaken premise
     * that this backend had no interrupt available.
     *
     * Return value: 0 = an edge arrived (a nonce is ready), 1 = timeout.
     * A timeout is normal and not an error -- it just means no nonce yet. */
    int ms = (timeout_ms < 0) ? 5 : timeout_ms;

    if (am01_bus_wait_irq(g_bus, ms) == 0)
        return 0;

    if (errno == ETIMEDOUT) {
        /* The display slice used to run here. The ILI9341 panel was removed
         * on 2026-09-05 -- the CYD replaced it -- so the mining loop no
         * longer yields anything to a second display. */
                return 1;
    }

    /* Anything else (bus error, line revoked) is worth surfacing, but the
     * caller's contract only distinguishes ready/not-ready, so degrade to a
     * timeout after a short sleep to avoid spinning on a persistent fault. */
    struct timespec ts = { .tv_sec = 0, .tv_nsec = 5L * 1000000L };
    nanosleep(&ts, NULL);
    return 1;
}

const char *miner_io_pipe_backend(void)
{
    return "gpio";
}
