/*
 * cyd_ota_send -- see cyd_ota_send.h.
 */
#include "cyd_ota_send.h"

#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "cyd_md5.h"
#include "cyd_proto.h"

static const char B64[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/* Encodes n bytes into out, which must hold 4*((n+2)/3)+1. Standard base64
 * with '=' padding, because the decoder on the panel is mbedtls and expects
 * exactly that. */
static size_t b64_encode(const unsigned char *in, size_t n, char *out)
{
    size_t o = 0;
    size_t i = 0;

    while (i + 3 <= n) {
        unsigned v = ((unsigned)in[i] << 16) | ((unsigned)in[i + 1] << 8)
                   | in[i + 2];
        out[o++] = B64[(v >> 18) & 0x3F];
        out[o++] = B64[(v >> 12) & 0x3F];
        out[o++] = B64[(v >> 6) & 0x3F];
        out[o++] = B64[v & 0x3F];
        i += 3;
    }

    if (i < n) {
        unsigned v = (unsigned)in[i] << 16;
        int      rem = 1;
        if (i + 1 < n) {
            v |= (unsigned)in[i + 1] << 8;
            rem = 2;
        }
        out[o++] = B64[(v >> 18) & 0x3F];
        out[o++] = B64[(v >> 12) & 0x3F];
        out[o++] = rem == 2 ? B64[(v >> 6) & 0x3F] : '=';
        out[o++] = '=';
    }

    out[o] = '\0';
    return o;
}

static int fail(char *err, size_t cap, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    if (err && cap)
        vsnprintf(err, cap, fmt, ap);
    va_end(ap);
    return -1;
}

/*
 * Wait for OTAOK / OTAERR, skipping anything else.
 *
 * SKIPPING MATTERS. The panel keeps running while it is being updated, so a
 * PING or a queued CMD can land in the middle of the transfer. Treating an
 * unrelated line as a protocol violation would abort a perfectly good update
 * because somebody touched the screen.
 */
static int expect_ok(const cyd_ota_io_t *io, unsigned long *acked,
                     char *err, size_t errcap)
{
    char line[256];

    /* Bounded, so a panel that chatters endlessly without ever answering
     * cannot hang the miner's panel thread. */
    for (int i = 0; i < 64; i++) {
        int n = io->readline(io->ctx, line, sizeof line,
                             CYD_OTA_ACK_TIMEOUT_MS);
        if (n < 0)
            return fail(err, errcap, "link error waiting for ack");
        if (n == 0)
            return fail(err, errcap, "timeout waiting for ack");

        if (strncmp(line, CYD_MSG_OTAERR, strlen(CYD_MSG_OTAERR)) == 0)
            return fail(err, errcap, "panel refused: %s",
                        line + strlen(CYD_MSG_OTAERR));

        if (strncmp(line, CYD_MSG_OTAOK, strlen(CYD_MSG_OTAOK)) == 0) {
            if (acked)
                *acked = strtoul(line + strlen(CYD_MSG_OTAOK), NULL, 10);
            return 0;
        }
        /* Something else entirely -- ignore and keep waiting. */
    }
    return fail(err, errcap, "no ack after 64 lines");
}

static int put(const cyd_ota_io_t *io, const char *buf, size_t len,
               char *err, size_t errcap)
{
    int n = io->write(io->ctx, buf, len);
    if (n < 0 || (size_t)n != len)
        return fail(err, errcap, "link error writing %zu bytes", len);
    return 0;
}

int cyd_ota_send_file(const char *path, const cyd_ota_io_t *io,
                      char *err, size_t errcap)
{
    if (!path || !io || !io->write || !io->readline)
        return fail(err, errcap, "bad arguments");

    FILE *f = fopen(path, "rb");
    if (!f)
        return fail(err, errcap, "cannot open %s: %s", path, strerror(errno));

    struct stat st;
    if (fstat(fileno(f), &st) != 0) {
        fclose(f);
        return fail(err, errcap, "cannot stat %s: %s", path, strerror(errno));
    }
    if (!S_ISREG(st.st_mode)) {
        fclose(f);
        return fail(err, errcap, "%s is not a regular file", path);
    }

    size_t total = (size_t)st.st_size;
    if (total < CYD_OTA_MIN_BYTES || total > CYD_OTA_MAX_BYTES) {
        fclose(f);
        return fail(err, errcap,
                    "%s is %zu bytes; expected %d..%d -- is this an ESP32 "
                    "firmware.bin?", path, total,
                    CYD_OTA_MIN_BYTES, CYD_OTA_MAX_BYTES);
    }

    /* ESP32 image magic. Catches the commonest operator error by far --
     * handing over firmware.elf, or the .bin for the wrong project -- before
     * a minute is spent transferring it and the panel rejects the digest. */
    int magic = fgetc(f);
    if (magic != 0xE9) {
        fclose(f);
        return fail(err, errcap,
                    "%s does not start with 0xE9, so it is not an ESP32 "
                    "image (got 0x%02X)", path, magic & 0xFF);
    }
    rewind(f);

    /* ---- digest first, in a separate pass ------------------------------
     * The MD5 has to go in OTABEGIN, before any data. Reading the file twice
     * costs nothing next to a 60-second transfer, and the alternative --
     * buffering 485KB in the miner's address space -- is not free on a CM4
     * that is also mining. */
    cyd_md5_t md5;
    uint8_t   digest[16];
    char      hex[33];
    cyd_md5_init(&md5);
    for (;;) {
        unsigned char buf[4096];
        size_t n = fread(buf, 1, sizeof buf, f);
        if (n == 0)
            break;
        cyd_md5_update(&md5, buf, n);
    }
    if (ferror(f)) {
        fclose(f);
        return fail(err, errcap, "read error hashing %s", path);
    }
    cyd_md5_final(&md5, digest);
    cyd_md5_hex(digest, hex);
    rewind(f);

    /* ---- begin ---------------------------------------------------------- */
    char line[CYD_LINE_MAX + 32];
    int  len = snprintf(line, sizeof line, "%s%zu %s\n",
                        CYD_MSG_OTABEGIN, total, hex);
    if (len <= 0 || (size_t)len >= sizeof line) {
        fclose(f);
        return fail(err, errcap, "OTABEGIN did not fit");
    }
    if (put(io, line, (size_t)len, err, errcap) != 0) {
        fclose(f);
        return -1;
    }
    if (expect_ok(io, NULL, err, errcap) != 0) {
        fclose(f);
        return -1;
    }

    /* ---- data ----------------------------------------------------------- */
    size_t sent = 0;
    while (sent < total) {
        unsigned char raw[CYD_OTA_CHUNK];
        size_t want = total - sent < CYD_OTA_CHUNK ? total - sent
                                                   : CYD_OTA_CHUNK;
        size_t n = fread(raw, 1, want, f);
        if (n != want) {
            fclose(f);
            return fail(err, errcap,
                        "%s shrank mid-transfer at %zu bytes", path, sent);
        }

        char b64[4 * ((CYD_OTA_CHUNK + 2) / 3) + 1];
        b64_encode(raw, n, b64);

        len = snprintf(line, sizeof line, "%s%s\n", CYD_MSG_OTADATA, b64);
        if (len <= 0 || (size_t)len >= sizeof line) {
            fclose(f);
            return fail(err, errcap, "chunk line did not fit");
        }
        if (put(io, line, (size_t)len, err, errcap) != 0) {
            fclose(f);
            return -1;
        }

        unsigned long acked = 0;
        if (expect_ok(io, &acked, err, errcap) != 0) {
            fclose(f);
            return -1;
        }
        sent += n;

        /* The panel reports what it has actually COMMITTED. If that ever
         * disagrees with what we think we sent, the two ends have different
         * ideas about the image and continuing would write a corrupt one --
         * the digest would catch it at the end, but an hour later and with a
         * far worse error message. */
        if (acked != sent) {
            fclose(f);
            return fail(err, errcap,
                        "panel acked %lu bytes, expected %zu", acked, sent);
        }

        if (io->progress)
            io->progress(io->ctx, sent, total);
    }
    fclose(f);

    /* ---- end ------------------------------------------------------------ */
    len = snprintf(line, sizeof line, "%s\n", CYD_MSG_OTAEND);
    if (put(io, line, (size_t)len, err, errcap) != 0)
        return -1;

    /* The panel verifies the MD5 here. A mismatch comes back as OTAERR and
     * the running firmware stays in charge. */
    if (expect_ok(io, NULL, err, errcap) != 0)
        return -1;

    return 0;
}
