/*
 * cyd_ota_send -- push a firmware image down the panel link.
 *
 * I/O GOES THROUGH CALLBACKS, not through the bus directly, for one reason:
 * the transfer is a protocol state machine with retries, timeouts, framing
 * and a digest, and none of that needs an FPGA to be tested. sim/ drives it
 * against a fake panel that can be made to NAK, time out, or lie about the
 * byte count -- failures that would otherwise only ever be seen on hardware,
 * once, at the worst moment.
 *
 * The caller supplies the transport; this file owns the protocol.
 */
#ifndef CYD_OTA_SEND_H
#define CYD_OTA_SEND_H

#include <stddef.h>

typedef struct {
    /* Write exactly len bytes. Return len, or <0 on a transport error. */
    int (*write)(void *ctx, const char *buf, size_t len);

    /* One line, newline stripped, NUL-terminated. Return its length, 0 on
     * timeout, <0 on a transport error. Lines that are not part of this
     * transfer (a PING from the panel, say) are the callback's to deliver and
     * this module's to skip. */
    int (*readline)(void *ctx, char *buf, size_t cap, int timeout_ms);

    /* Optional; called as chunks are acknowledged. May be NULL. */
    void (*progress)(void *ctx, size_t done, size_t total);

    void *ctx;
} cyd_ota_io_t;

/*
 * Send `path` to the panel. Returns 0 on success, -1 on failure with a
 * human-readable reason in `err`.
 *
 * On success the panel has verified the MD5 and is rebooting into the new
 * image. On failure the panel's RUNNING firmware is untouched -- every abort
 * path leaves the spare slot half-written and unbooted, never the live one.
 */
int cyd_ota_send_file(const char *path, const cyd_ota_io_t *io,
                      char *err, size_t errcap);

#endif /* CYD_OTA_SEND_H */
