/*
 * AM01 + CM4 — mining daemon I/O layer over GPIO bus
 *
 * Drop-in replacement for miner_io_pipe.h (Avalon-MM) on GPIO.
 * Adapts am01_gpio_bus.c to the miner_pipe.c API, so the daemon needs zero changes.
 *
 * Usage: compile with miner_pipe.c unchanged; link miner_io_gpio.c instead of
 * miner_io_pipe.c. The include line stays "#include "miner_io_pipe.h"".
 */

#ifndef MINER_IO_PIPE_H
#define MINER_IO_PIPE_H

#include <stdint.h>

/* =====================================================================
 * Public API — identical to miner_io_pipe.h for drop-in compatibility.
 * ===================================================================== */

/* Initialize the GPIO bus and miner interface.
 * Returns 0 on success, -1 on error (run as root for GPIO access). */
int miner_io_pipe_init(void);

/* Shut down and release resources. */
void miner_io_pipe_shutdown(void);

/* Read version register (GPIO wrapper version). */
uint32_t miner_io_pipe_version(void);

/* Read seed register (baked-in epoch ODOKEY from bitstream).
 * For AM01, this is read from FPGA register 0x00 (VERSION/SEED).
 * Note: the current GPIO wrapper may not expose SEED independently;
 * returns 0 if not available. */
uint32_t miner_io_pipe_seed(void);

/* Submit a work item: 19-word header (bytes 0..75, nonce is swept by FPGA)
 * and 8-word target (256-bit share target). Returns 0 on success. */
int miner_io_pipe_dispatch(const uint8_t header[80], const uint8_t target[32]);

/* Poll for a found nonce without blocking.
 * Returns:
 *   0 if a nonce was read (stored in *out_nonce if non-NULL)
 *   1 if no nonce is pending (FSTATUS.valid == 0)
 *   -1 on error
 */
int miner_io_pipe_poll(uint32_t *out_nonce);

/* Wait for a nonce or timeout.
 * Returns:
 *   0 if a nonce is ready (check with miner_io_pipe_poll)
 *   1 if timeout (no nonce ready after timeout_ms)
 *   -1 on error
 * The GPIO backend has no interrupt, so this sleeps briefly then returns.
 * Capped at 5ms per the original /dev/mem backend for low latency. */
int miner_io_pipe_wait(int timeout_ms);

/* Return the backend name (for logging/status). */
const char *miner_io_pipe_backend(void);

/* The open bus handle, or NULL before miner_io_pipe_init().
 *
 * Exposed for thermal_am01.c, which reads the FPGA's XADC temperature and
 * fan registers over this same bus. The alternative -- a second
 * am01_bus_open() on the same gpiochip -- would mean two owners of one set
 * of GPIO lines, and the kernel would refuse the second request-lines call.
 *
 * Callers should go through the am01_bus_* accessors rather than reaching
 * past them. */
struct am01_bus;
struct am01_bus *miner_io_gpio_bus(void);

#endif /* MINER_IO_PIPE_H */
