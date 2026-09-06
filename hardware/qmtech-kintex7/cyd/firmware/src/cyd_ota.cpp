/*
 * cyd_ota -- see include/cyd_ota.h for why the application does this and not
 * esptool.
 */
#include "cyd_ota.h"

#include <Update.h>
#include <ctype.h>
#include <string.h>
#include <stdlib.h>

#include "mbedtls/base64.h"

extern "C" {
#include "cyd_proto.h"
}

static bool     s_active;
static uint32_t s_total;        /* bytes the host says are coming */
static uint32_t s_written;      /* bytes actually in flash        */
static char     s_error[64];
static uint32_t s_last_ms;      /* millis() of the last accepted byte */

/* HOW LONG A TRANSFER MAY GO QUIET BEFORE IT IS ABANDONED.
 *
 * The host writes a chunk and waits for the ack before sending the next, so in
 * a healthy transfer this is reset several times a second. 30s is far beyond
 * any legitimate gap, and short enough that someone watching a frozen
 * percentage does not conclude the panel has died and pull the power --
 * which is the failure this path exists to avoid, because recovering a
 * half-flashed panel means opening the case. */
#define OTA_STALL_MS 30000u

/* Abort without replying. fail() below needs a Stream to send OTAERR on; a
 * timeout has nobody to answer, and the host has already given up. */
static void ota_abort(const char *why)
{
    snprintf(s_error, sizeof s_error, "%s", why);
    /* UNCONDITIONAL, not guarded on s_active. There is a window between
     * Update.begin() succeeding and s_active being set in which a failure
     * would otherwise leave UpdateClass running with _size > 0: every later
     * OTABEGIN would skip its abort, Update.begin() would refuse with
     * "already running", and OTA would be dead until a power cycle.
     * abort() on a stopped Update is harmless. */
    Update.abort();
    s_active  = false;
    s_total   = 0;
    s_written = 0;
    s_last_ms = 0;
}

bool cyd_ota_active(void)
{
    /* THE TIMEOUT LIVES HERE because this is the only thing main.cpp still
     * calls while an update owns the panel -- loop() returns early on it. Any
     * other home would need a caller that does not run. */
    if (s_active && (uint32_t)(millis() - s_last_ms) > OTA_STALL_MS)
        ota_abort("host went quiet");
    return s_active;
}

const char *cyd_ota_take_error(void)
{
    static char snapshot[sizeof s_error];
    if (s_error[0] == '\0')
        return "";
    memcpy(snapshot, s_error, sizeof snapshot);
    s_error[0] = '\0';          /* consumed: the caller draws it once */
    return snapshot;
}

int cyd_ota_percent(void)
{
    if (s_total == 0)
        return 0;
    /* 64-bit intermediate: 1.25MB * 100 overflows nothing here, but the habit
     * costs nothing and the next size bump might. */
    return (int)(((uint64_t)s_written * 100u) / s_total);
}

/* Abort and report. Update.abort() leaves the RUNNING image untouched -- the
 * spare slot is the only thing that was being written. */
static void fail(Stream &reply, const char *why)
{
    ota_abort(why);
    reply.print(CYD_MSG_OTAERR);
    reply.print(why);
    reply.print("\n");
}

static void ack(Stream &reply)
{
    reply.print(CYD_MSG_OTAOK);
    reply.print(s_written);
    reply.print("\n");
}

/* ------------------------------------------------------------------ begin */
static void handle_begin(const char *args, Stream &reply)
{
    if (s_active) {
        /* A second OTABEGIN means the host restarted mid-transfer. Drop the
         * partial write and take the new one rather than interleaving two
         * images into one slot. */
        Update.abort();
        s_active = false;
    }

    char *end = NULL;
    unsigned long size = strtoul(args, &end, 10);
    if (end == args) {
        fail(reply, "bad size");
        return;
    }
    while (*end == ' ')
        end++;

    /* MD5 is 32 hex characters and is NOT optional: it is the entire defence
     * against booting a corrupted image, and it must be set before the first
     * write so Update can hash as it goes. */
    char md5[33];
    size_t n = 0;
    while (n < 32 && isxdigit((unsigned char)end[n])) {
        md5[n] = (char)tolower((unsigned char)end[n]);
        n++;
    }
    md5[n] = '\0';
    if (n != 32) {
        fail(reply, "bad md5");
        return;
    }

    if (size < CYD_OTA_MIN_BYTES || size > CYD_OTA_MAX_BYTES) {
        fail(reply, "size out of range");
        return;
    }

    /* U_FLASH: the app partition that is NOT running. Update picks it. */
    if (!Update.begin(size, U_FLASH)) {
        fail(reply, Update.errorString());
        return;
    }
    if (!Update.setMD5(md5)) {
        fail(reply, "md5 rejected");
        return;
    }

    s_active  = true;
    s_last_ms = millis();
    s_total   = (uint32_t)size;
    s_written = 0;
    s_error[0] = '\0';
    ack(reply);
}

/* ------------------------------------------------------------------- data */
static void handle_data(const char *b64, Stream &reply)
{
    if (!s_active) {
        fail(reply, "no transfer");
        return;
    }

    uint8_t buf[CYD_OTA_CHUNK + 8];
    size_t  out_len = 0;
    size_t  in_len  = strlen(b64);

    int rc = mbedtls_base64_decode(buf, sizeof buf, &out_len,
                                   (const unsigned char *)b64, in_len);
    if (rc != 0) {
        fail(reply, "base64");
        return;
    }
    if (out_len == 0) {
        fail(reply, "empty chunk");
        return;
    }
    if (s_written + out_len > s_total) {
        /* The host is sending more than it declared. Refuse rather than
         * truncate: the size was used to size the partition write. */
        fail(reply, "overrun");
        return;
    }

    /* Write BEFORE acknowledging. That ordering is the flow control: the host
     * waits for the ack, so it cannot outrun a flash erase. */
    if (Update.write(buf, out_len) != out_len) {
        fail(reply, Update.errorString());
        return;
    }
    s_written += out_len;
    s_last_ms  = millis();   /* progress: the transfer is alive */
    ack(reply);
}

/* -------------------------------------------------------------------- end */
static void handle_end(Stream &reply)
{
    if (!s_active) {
        fail(reply, "no transfer");
        return;
    }
    if (s_written != s_total) {
        fail(reply, "short image");
        return;
    }

    /* end(true) finalises AND checks the MD5 set at begin. If the hash does
     * not match, the boot partition is NOT switched and the running firmware
     * stays in charge -- which is the whole safety property. */
    if (!Update.end(true)) {
        fail(reply, Update.errorString());
        return;
    }
    if (!Update.isFinished()) {
        fail(reply, "not finished");
        return;
    }

    s_active = false;
    ack(reply);
    reply.flush();

    /* Let the ack reach the host before the radio silence of a reboot --
     * otherwise the host reports a timeout on a transfer that in fact
     * succeeded, and the operator retries an update that already applied. */
    delay(250);
    ESP.restart();
}

/* ------------------------------------------------------------------ entry */
bool cyd_ota_handle_line(const char *line, Stream &reply)
{
    if (strncmp(line, CYD_MSG_OTABEGIN, strlen(CYD_MSG_OTABEGIN)) == 0) {
        handle_begin(line + strlen(CYD_MSG_OTABEGIN), reply);
        return true;
    }
    if (strncmp(line, CYD_MSG_OTADATA, strlen(CYD_MSG_OTADATA)) == 0) {
        handle_data(line + strlen(CYD_MSG_OTADATA), reply);
        return true;
    }
    /* Exact match: OTAEND has no arguments, and a prefix test here would also
     * swallow anything else beginning with those six characters. */
    if (strcmp(line, CYD_MSG_OTAEND) == 0) {
        handle_end(reply);
        return true;
    }
    return false;
}
