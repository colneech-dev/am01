/*
 * test_cyd_ota_send -- drive cyd_ota_send against a fake panel.
 *
 * The point is the FAILURE paths. A happy-path OTA gets exercised every time
 * anyone updates a panel; a panel that NAKs the third chunk, or acknowledges
 * a byte count that does not match, or goes silent halfway, gets exercised
 * once -- on hardware, at night, with the case shut. So the fake panel here
 * can be told to do each of those on demand.
 *
 * It also reassembles the image from the base64 it receives and checks it
 * byte-for-byte against the original, which tests the encoder end to end
 * rather than trusting it.
 *
 *   cc -o t test_cyd_ota_send.c ../host/cyd_ota_send.c ../host/cyd_md5.c
 *   ./t
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../host/cyd_md5.h"
#include "../host/cyd_ota_send.h"
#include "../host/cyd_proto.h"

static int checks, errors;
static void ok(int cond, const char *what)
{
    checks++;
    if (cond) printf("  PASS  %s\n", what);
    else { printf("  FAIL  %s\n", what); errors++; }
}

/* ------------------------------------------------------------ fake panel */

enum fake_mode {
    F_OK = 0,
    F_NAK_BEGIN,
    F_NAK_CHUNK,      /* NAK on chunk `trip`                       */
    F_TIMEOUT,        /* go silent from chunk `trip`               */
    F_WRONG_ACK,      /* acknowledge a bogus count at chunk `trip` */
    F_CHATTER,        /* interleave PINGs; must still succeed      */
    F_NAK_END
};

typedef struct {
    enum fake_mode mode;
    int   trip;

    char  inbuf[8192];      /* partial line from the sender */
    size_t inlen;

    char  reply[4096];      /* queued replies, newline separated */
    size_t rlen, rpos;

    unsigned char *image;   /* what the panel reassembled */
    size_t         imglen, imgcap;

    int   chunks;
    int   saw_begin, saw_end;
    char  begin_md5[64];
    size_t begin_size;
    int   silent;
} fake_t;

static void qreply(fake_t *f, const char *s)
{
    size_t n = strlen(s);
    if (f->rlen + n + 1 < sizeof f->reply) {
        memcpy(f->reply + f->rlen, s, n);
        f->rlen += n;
        f->reply[f->rlen++] = '\n';
    }
}

static int b64val(char c)
{
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

static void b64_decode_append(fake_t *f, const char *s)
{
    unsigned acc = 0;
    int bits = 0;
    for (; *s && *s != '='; s++) {
        int v = b64val(*s);
        if (v < 0) continue;
        acc = (acc << 6) | (unsigned)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (f->imglen < f->imgcap)
                f->image[f->imglen++] = (unsigned char)((acc >> bits) & 0xFF);
        }
    }
}

/* One complete line from the sender. */
static void fake_line(fake_t *f, const char *line)
{
    if (strncmp(line, CYD_MSG_OTABEGIN, strlen(CYD_MSG_OTABEGIN)) == 0) {
        f->saw_begin = 1;
        sscanf(line + strlen(CYD_MSG_OTABEGIN), "%zu %63s",
               &f->begin_size, f->begin_md5);
        if (f->mode == F_NAK_BEGIN) qreply(f, "OTAERR no space");
        else                        qreply(f, "OTAOK 0");
        return;
    }

    if (strncmp(line, CYD_MSG_OTADATA, strlen(CYD_MSG_OTADATA)) == 0) {
        f->chunks++;

        if (f->mode == F_NAK_CHUNK && f->chunks == f->trip) {
            qreply(f, "OTAERR flash write failed");
            return;
        }
        if (f->mode == F_TIMEOUT && f->chunks >= f->trip) {
            f->silent = 1;      /* answer nothing, ever again */
            return;
        }

        b64_decode_append(f, line + strlen(CYD_MSG_OTADATA));

        char ack[64];
        if (f->mode == F_WRONG_ACK && f->chunks == f->trip)
            snprintf(ack, sizeof ack, "OTAOK %zu", f->imglen + 17);
        else
            snprintf(ack, sizeof ack, "OTAOK %zu", f->imglen);

        if (f->mode == F_CHATTER) {
            qreply(f, "PING");          /* the panel is still a panel */
            qreply(f, "CMD fan_boost 1");
        }
        qreply(f, ack);
        return;
    }

    if (strcmp(line, CYD_MSG_OTAEND) == 0) {
        f->saw_end = 1;
        if (f->mode == F_NAK_END) qreply(f, "OTAERR md5 mismatch");
        else {
            char ack[64];
            snprintf(ack, sizeof ack, "OTAOK %zu", f->imglen);
            qreply(f, ack);
        }
        return;
    }
}

static int fake_write(void *ctx, const char *buf, size_t len)
{
    fake_t *f = (fake_t *)ctx;
    for (size_t i = 0; i < len; i++) {
        char c = buf[i];
        if (c == '\n') {
            f->inbuf[f->inlen] = '\0';
            fake_line(f, f->inbuf);
            f->inlen = 0;
        } else if (f->inlen + 1 < sizeof f->inbuf) {
            f->inbuf[f->inlen++] = c;
        }
    }
    return (int)len;
}

static int fake_readline(void *ctx, char *buf, size_t cap, int timeout_ms)
{
    (void)timeout_ms;
    fake_t *f = (fake_t *)ctx;
    if (f->silent)
        return 0;                       /* timeout */
    if (f->rpos >= f->rlen)
        return 0;

    size_t n = 0;
    while (f->rpos < f->rlen && f->reply[f->rpos] != '\n' && n + 1 < cap)
        buf[n++] = f->reply[f->rpos++];
    if (f->rpos < f->rlen && f->reply[f->rpos] == '\n')
        f->rpos++;
    buf[n] = '\0';

    if (f->rpos >= f->rlen) { f->rpos = 0; f->rlen = 0; }
    return (int)n;
}

/* ------------------------------------------------------------------ util */

static const char *TMP = "/tmp/cyd_ota_test.bin";

static unsigned char *make_image(size_t n, const char *path, int magic)
{
    unsigned char *img = malloc(n);
    for (size_t i = 0; i < n; i++)
        img[i] = (unsigned char)(i * 37u + (i >> 9));
    img[0] = (unsigned char)magic;
    FILE *f = fopen(path, "wb");
    fwrite(img, 1, n, f);
    fclose(f);
    return img;
}

static int run(fake_t *f, size_t n, char *err, size_t errcap,
               unsigned char **orig_out)
{
    unsigned char *orig = make_image(n, TMP, 0xE9);
    f->imgcap = n + 4096;
    f->image  = malloc(f->imgcap);
    f->imglen = 0;

    cyd_ota_io_t io = { fake_write, fake_readline, NULL, f };
    int rc = cyd_ota_send_file(TMP, &io, err, errcap);

    if (orig_out) *orig_out = orig; else free(orig);
    return rc;
}

int main(void)
{
    char err[256];
    printf("=== cyd_ota_send against a fake panel ===\n\n");

    /* ---- happy path -------------------------------------------------- */
    printf("-- a good transfer --\n");
    {
        fake_t f = {0}; f.mode = F_OK;
        unsigned char *orig = NULL;
        size_t n = 70000;
        err[0] = '\0';
        int rc = run(&f, n, err, sizeof err, &orig);

        ok(rc == 0, "succeeds");
        if (rc != 0) printf("        err: %s\n", err);
        ok(f.saw_begin && f.saw_end, "sent OTABEGIN and OTAEND");
        ok(f.begin_size == n, "declared the right size");
        ok(f.imglen == n, "panel reassembled the right length");
        ok(orig && memcmp(orig, f.image, n) == 0,
           "reassembled image is byte-identical (base64 round trip)");

        /* The digest the panel was promised must be the digest of the file. */
        cyd_md5_t c; unsigned char d[16]; char hex[33];
        cyd_md5_init(&c); cyd_md5_update(&c, orig, n); cyd_md5_final(&c, d);
        cyd_md5_hex(d, hex);
        ok(strcmp(hex, f.begin_md5) == 0, "OTABEGIN carried the correct MD5");

        free(orig); free(f.image);
    }

    /* ---- the panel is still a panel ---------------------------------- */
    printf("\n-- unrelated traffic during the transfer --\n");
    {
        fake_t f = {0}; f.mode = F_CHATTER;
        err[0] = '\0';
        int rc = run(&f, 70000, err, sizeof err, NULL);
        ok(rc == 0, "PING/CMD interleaved mid-transfer is skipped, not fatal");
        if (rc != 0) printf("        err: %s\n", err);
        free(f.image);
    }

    /* ---- refusals ---------------------------------------------------- */
    printf("\n-- the panel says no --\n");
    {
        fake_t f = {0}; f.mode = F_NAK_BEGIN;
        err[0] = '\0';
        ok(run(&f, 70000, err, sizeof err, NULL) == -1, "NAK at OTABEGIN fails");
        ok(strstr(err, "no space") != NULL, "and reports the panel's reason");
        free(f.image);
    }
    {
        fake_t f = {0}; f.mode = F_NAK_CHUNK; f.trip = 3;
        err[0] = '\0';
        ok(run(&f, 70000, err, sizeof err, NULL) == -1, "NAK mid-transfer fails");
        ok(strstr(err, "flash write failed") != NULL, "reason is surfaced");
        free(f.image);
    }
    {
        fake_t f = {0}; f.mode = F_NAK_END;
        err[0] = '\0';
        ok(run(&f, 70000, err, sizeof err, NULL) == -1,
           "a digest mismatch at OTAEND fails");
        free(f.image);
    }

    /* ---- the silent panel -------------------------------------------- */
    printf("\n-- the panel stops answering --\n");
    {
        fake_t f = {0}; f.mode = F_TIMEOUT; f.trip = 5;
        err[0] = '\0';
        ok(run(&f, 70000, err, sizeof err, NULL) == -1, "a timeout fails");
        ok(strstr(err, "timeout") != NULL, "and says so");
        free(f.image);
    }

    /* ---- the lying panel --------------------------------------------- */
    printf("\n-- the panel acks a count that does not match --\n");
    {
        fake_t f = {0}; f.mode = F_WRONG_ACK; f.trip = 4;
        err[0] = '\0';
        ok(run(&f, 70000, err, sizeof err, NULL) == -1,
           "a mismatched byte count aborts");
        ok(strstr(err, "acked") != NULL, "and reports both counts");
        free(f.image);
    }

    /* ---- rejected before a single byte moves -------------------------- */
    printf("\n-- refused up front --\n");
    {
        fake_t f = {0};
        free(make_image(70000, TMP, 0x7F));    /* ELF-ish, not an ESP32 image */
        cyd_ota_io_t io = { fake_write, fake_readline, NULL, &f };
        err[0] = '\0';
        int rc = cyd_ota_send_file(TMP, &io, err, sizeof err);
        ok(rc == -1, "a file not starting 0xE9 is refused");
        ok(strstr(err, "0xE9") != NULL, "and says why");
        ok(f.saw_begin == 0, "without sending OTABEGIN -- nothing was written");
    }
    {
        fake_t f = {0};
        free(make_image(1024, TMP, 0xE9));     /* far too small */
        cyd_ota_io_t io = { fake_write, fake_readline, NULL, &f };
        err[0] = '\0';
        ok(cyd_ota_send_file(TMP, &io, err, sizeof err) == -1,
           "an implausibly small file is refused");
        ok(f.saw_begin == 0, "also without sending OTABEGIN");
    }
    {
        fake_t f = {0};
        cyd_ota_io_t io = { fake_write, fake_readline, NULL, &f };
        err[0] = '\0';
        ok(cyd_ota_send_file("/nonexistent/nope.bin", &io, err, sizeof err) == -1,
           "a missing file is refused");
    }

    remove(TMP);
    printf("\n");
    if (!errors) { printf("=== ALL %d CHECKS PASSED ===\n", checks); return 0; }
    printf("=== %d of %d CHECK(S) FAILED ===\n", errors, checks);
    return 1;
}
