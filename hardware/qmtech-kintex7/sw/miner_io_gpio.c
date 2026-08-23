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

    g_bus = am01_bus_open("gpiochip0");
    if (!g_bus) {
        fprintf(stderr, "miner_io_pipe_init: am01_bus_open failed\n");
        return -1;
    }

    /* Version and seed are bitstream constants. The GPIO wrapper doesn't
     * expose these as readable registers yet, so hardcode placeholders.
     * TODO: extend odocrypt_gpio_wrapper.v to expose SEED as a readable register. */
    g_version = 0x00010000;  /* GPIO wrapper v1.0 */
    g_seed = 0;              /* Not yet readable from wrapper */

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

    /* The am01_gpio_bus API doesn't have a non-blocking status check yet.
     * For now, this blocks momentarily on nonce reads. In production,
     * extend am01_gpio_bus.h with a non-blocking poll variant.
     *
     * Return values match miner_io_pipe.c semantics:
     *   0 = nonce was read
     *   1 = no nonce pending
     *   -1 = error
     */
    uint32_t nonce = 0;
    int rc = am01_bus_read_nonce(g_bus, &nonce);
    if (rc < 0)
        return -1;

    if (out_nonce)
        *out_nonce = nonce;
    return 0;
}

int miner_io_pipe_wait(int timeout_ms)
{
    if (!g_bus)
        return -1;

    /* The GPIO backend (bit-banged GPIO) has no interrupt, so we sleep
     * briefly and let the caller poll. Cap at 5ms (original /dev/mem backend)
     * for low latency. Return value: 1 = timeout (always, no IRQ available). */
    unsigned ms = (timeout_ms < 0 || timeout_ms > 5) ? 5u : (unsigned)timeout_ms;
    struct timespec ts = { .tv_sec  = ms / 1000,
                           .tv_nsec = (long)(ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
    return 1;   /* Always "timeout" — GPIO backend has no interrupt */
}

const char *miner_io_pipe_backend(void)
{
    return "gpio";
}
