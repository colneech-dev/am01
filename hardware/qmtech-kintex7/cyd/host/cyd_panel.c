/*
 * cyd_panel.c -- see cyd_panel.h for why this is a thread inside odo-miner
 * rather than a daemon of its own.
 *
 * Two jobs, one second apart:
 *   - push /run/odod/status.json to the panel as a STATUS line
 *   - read command lines back and apply them to the control files the daemon
 *     already polls
 *
 * IT TOUCHES NO MINER STATE. Commands land on /run/odod/fan_boost,
 * /run/odod/reset_stats and /boot/am01-miner.conf -- the same surface odo-ui
 * and odo-webd use. That keeps this thread unable to corrupt anything the
 * mining loop depends on: the worst it can do is create a file the daemon was
 * already prepared to find.
 */

#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE

#include "cyd_panel.h"
#include "cyd_cmd.h"
#include "cyd_ota_send.h"
#include "cyd_proto.h"

#include "miner_io_gpio.h"
#include "am01_gpio_bus.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>       /* clock_gettime, for the OTA ack timeout */
#include <unistd.h>

/* UART_STAT, unchanged since 0x0203:
 *   {rx_err[3:0], tx_cnt[4:0], rx_cnt[4:0], tx_full, rx_empty}
 *
 * The RX FIFO is 256 bytes as of 0x0204, but this layout did NOT change: the
 * 5-bit rx_cnt here simply saturates at 31, and nothing in this file reads it
 * -- the RX side drains until rx_empty. The exact occupancy has its own
 * 16-bit register (CYD_REG_UART_RXCNT) for anyone who wants it. */
#define ST_RX_EMPTY(v)  ((v) & 0x1u)
#define ST_TX_FULL(v)   (((v) >> 1) & 0x1u)
#define ST_TX_CNT(v)    (((v) >> 7) & 0x1Fu)
#define TX_FIFO_DEPTH   16

#define PANEL_MIN_VERSION 0x0204

static volatile int g_stop;
static pthread_t    g_thread;
static int          g_running;

/* Line assembly for the RX side, at file scope so uart_write() can keep
 * servicing it while it waits for the TX FIFO to drain.
 *
 * WITHOUT THAT, a status push starves RX. A 663-byte line at 115200 takes
 * ~58ms, and the FPGA's RX FIFO is 16 bytes -- about 1.4ms of incoming data.
 * A command sent while a status is going out would lose bytes mid-line, be
 * rejected as malformed, and simply not happen. The symptom is a button that
 * works most of the time, which is the worst kind. */
typedef struct {
    char   buf[CYD_LINE_MAX];
    size_t len;
    int    overflow;
} rx_state_t;

static rx_state_t g_rx;

/* A command parsed while a status line was being transmitted, to be executed
 * once transmission finishes. See the may_apply note in uart_write(). */
static cyd_cmd_t g_deferred;
static int       g_deferred_valid;

/* ---- UART, over the register bus -------------------------------------- */

static void drain_rx(am01_bus_t *bus, int may_apply);

/* Declared here because apply() sets the deadline and the forwarder below
 * reads it, and apply() comes first in the file. */
static uint64_t now_ms(void);
static uint64_t g_scan_wait_until;

/* Write the WHOLE line, waiting for the FIFO to drain as needed.
 *
 * The first version returned early whenever the FIFO filled, and the caller
 * ignored the short count. The FIFO is 16 bytes and a status line is ~663, so
 * roughly 16 bytes went out per second -- no newline, nothing the far end
 * could ever parse. am01-uartd.c had the retry loop; dropping it here was the
 * bug.
 *
 * BOUNDED, so a dead link cannot wedge the thread: 663 bytes at 115200 baud
 * is ~58ms, and the budget below allows about 2s before giving up. A partial
 * line is left partial -- the far end drops it at the next newline and gets a
 * whole one a second later, which is the right failure for a display. */
static int uart_write(am01_bus_t *bus, const char *buf, size_t len)
{
    size_t n = 0;
    int spins = 0;

    while (n < len) {
        uint16_t st;
        if (am01_bus_read_reg(bus, CYD_REG_UART_STAT, &st) < 0)
            return (int)n;

        /* DRAIN TO EMPTY, THEN WRITE AT MOST HALF THE FIFO.
         *
         * The obvious version -- room = DEPTH - tx_cnt, then write that many
         * -- is what was here, and it silently truncated lines. tx_cnt is
         * sampled ONCE and then up to `room` bytes are pushed in a tight loop
         * with no re-read, so any latency in that count makes room an
         * overestimate; uart_bridge.v drops a write into a full FIFO without
         * complaining ("a drop here is a host bug", line 159) and the loss is
         * invisible from this side.
         *
         * It cost 4 bytes off the end of one OTA chunk in ~986 on
         * 2026-09-05 -- the transfer aborted on the byte-count check, having
         * been fine for 58 chunks. The same race has been quietly corrupting
         * the occasional 655-byte STATUS line all along; those just look like
         * a panel that missed an update, which is why it was never chased.
         *
         * So: only write when the FIFO reads EMPTY, and then no more than
         * half its depth. Even if the count is a read stale, 8 outstanding
         * plus 8 written cannot exceed 16. This costs nothing real -- 8 bytes
         * at 115200 is 694us, which is line rate, so the link is the limit
         * either way. */
        unsigned cnt  = ST_TX_CNT(st);
        unsigned room = (ST_TX_FULL(st) || cnt != 0) ? 0 : (TX_FIFO_DEPTH / 2);

        if (!room) {
            if (++spins > 2000)          /* ~2s at 1ms */
                return (int)n;
            /* Service RX while we wait. See the note on rx_state_t: without
             * this a command arriving during a status push loses bytes. */
            /* may_apply = 0. Servicing RX here is necessary, but ACTING
             * on a command is not safe mid-transmission:
             *
             *   - apply() answers PING with uart_write(), which would splice
             *     "PONG\n" into the middle of the status line already going
             *     out. The panel would see one line broken into two, both
             *     unparseable.
             *   - drain_rx resets g_rx.len only AFTER apply() returns, so a
             *     nested call would append incoming bytes at the previous
             *     line's offset and then have its work zeroed by the outer
             *     frame.
             *
             * So lines are collected here and executed by the main loop.
             * Only reachable today via a PING the firmware never originates,
             * but any stray byte on the wire arms it. */
            drain_rx(bus, 0);
            usleep(1000);
            continue;
        }
        spins = 0;

        for (unsigned i = 0; i < room && n < len; i++) {
            if (am01_bus_write_reg(bus, CYD_REG_UART_DATA,
                                   (uint8_t)buf[n]) < 0)
                return (int)n;
            n++;
        }
    }
    return (int)n;
}

/* ---- command side ------------------------------------------------------ */

static void touch_file(const char *path)
{
    FILE *f = fopen(path, "w");
    if (f) fclose(f);
}

/* ---- privileged requests ------------------------------------------------
 *
 * THIS THREAD CANNOT DO ANY OF THIS ITSELF. odo-miner.service sets User=miner;
 * /boot is root-owned vfat, /etc/wpa_supplicant is root-owned, and systemctl
 * needs root. The previous version of this file called fopen() and system()
 * directly and reported failure to stderr, so the panel drew Set Pool, WiFi
 * Setup, Restart and Reboot -- and every one of them was a no-op on a real
 * board.
 *
 * So we ASK. A request file goes into /run/odod/request/ (this service's own
 * RuntimeDirectory, so no new permissions are needed anywhere), and
 * am01-panel-helper.path notices and runs the helper as root. The helper
 * re-validates everything from scratch: reaching this directory only takes the
 * miner account, so the helper -- not this file -- is the privilege boundary.
 *
 * Written to a temp name and renamed, because the path unit watches for the
 * file APPEARING. A half-written request must never be visible.
 */
#define CYD_REQ_DIR "/run/odod/request"

static void request_write(const char *verb, const char *body)
{
    char dir_ok[] = CYD_REQ_DIR;
    (void)mkdir(dir_ok, 0755);        /* EEXIST is the normal case */

    char tmp[128], fin[128];
    snprintf(tmp, sizeof tmp, "%s/.%s.tmp", CYD_REQ_DIR, verb);
    snprintf(fin, sizeof fin, "%s/%s", CYD_REQ_DIR, verb);

    FILE *f = fopen(tmp, "w");
    if (!f) {
        fprintf(stderr, "[cyd] %s: cannot write %s: %s\n",
                verb, tmp, strerror(errno));
        return;
    }
    if (body && *body)
        fputs(body, f);
    if (fflush(f) != 0 || fsync(fileno(f)) != 0) {
        int e = errno;
        fclose(f);
        unlink(tmp);
        fprintf(stderr, "[cyd] %s: flush failed: %s\n", verb, strerror(e));
        return;
    }
    if (fclose(f) != 0) {
        unlink(tmp);
        fprintf(stderr, "[cyd] %s: close failed: %s\n", verb, strerror(errno));
        return;
    }
    if (rename(tmp, fin) != 0) {
        fprintf(stderr, "[cyd] %s: rename failed: %s\n", verb, strerror(errno));
        unlink(tmp);
        return;
    }
    fprintf(stderr, "[cyd] %s requested from the front panel\n", verb);
}

/* LINE ORIENTED, one field per line, so nothing in a field can be mistaken for
 * a delimiter -- a WPA passphrase may contain spaces, and an SSID may too. */
static void apply_set_pool(const cyd_cmd_t *c)
{
    /* host(64) + port + worker(96) + pass(32) + separators. Generous so the
     * compiler can prove no truncation rather than merely being right. */
    char body[384];
    snprintf(body, sizeof body, "%s\n%d\n%s\n%s\n",
             c->host, c->port, c->worker, c->pass);
    request_write("set_pool", body);
}

static void apply_set_wifi(const cyd_cmd_t *c)
{
    /* ssid(64) + psk(80) + two newlines, rounded up so the compiler can see
     * it cannot truncate. */
    char body[256];
    snprintf(body, sizeof body, "%s\n%s\n", c->ssid, c->psk);
    /* The PSK is in the request file, which is why the helper's directory is
     * 0755 and the file itself is short-lived -- and why the helper writes
     * wpa_supplicant.conf 0600 and never logs the passphrase. */
    request_write("set_wifi", body);
}

static void apply(const cyd_cmd_t *c, am01_bus_t *bus)
{
    switch (c->kind) {
    case CYD_CMD_KIND_PING: {
        static const char pong[] = CYD_MSG_PONG "\n";
        uart_write(bus, pong, sizeof pong - 1);
        break;
    }
    case CYD_CMD_KIND_FAN_BOOST:
        if (c->fan_on) touch_file(CYD_FAN_BOOST_PATH);
        else           unlink(CYD_FAN_BOOST_PATH);
        fprintf(stderr, "[cyd] fan boost %s\n", c->fan_on ? "ON" : "off");
        break;
    case CYD_CMD_KIND_RESET_STATS:
        touch_file(CYD_RESET_STAT_PATH);
        fprintf(stderr, "[cyd] session stats reset requested\n");
        break;
    case CYD_CMD_KIND_REBOOT:
        /* Two touches on the panel already guard this (test_cyd_ui.c proves
         * the confirm path exhaustively); the helper carries it out. */
        request_write("reboot", NULL);
        break;
    case CYD_CMD_KIND_SET_POOL:
        apply_set_pool(c);
        break;
    case CYD_CMD_KIND_RESTART:
        request_write("restart", NULL);
        break;

    case CYD_CMD_KIND_WIFI_SCAN:
        /* The helper does the scanning -- it needs CAP_NET_ADMIN and this
         * thread does not have it. Any stale result is removed first, so the
         * reply that goes back is unambiguously the answer to THIS request
         * rather than whatever the last scan found. */
        unlink(CYD_WIFI_SCAN_PATH);
        /* 3.5s is a measured scan on this board; 20s covers a slow one
         * and a busy helper without leaving the panel waiting for ever
         * on a request that was dropped. */
        g_scan_wait_until = now_ms() + 20000;
        request_write("wifi_scan", NULL);
        break;
    case CYD_CMD_KIND_SET_WIFI:
        apply_set_wifi(c);
        break;
    case CYD_CMD_KIND_NONE:
    default:
        break;
    }
}

/* ---- the thread -------------------------------------------------------- */

/* Read whatever is waiting and act on any complete lines. Called both from
 * the main loop and from inside uart_write()'s wait, so a command is never
 * lost behind an outgoing status. */
static void drain_rx(am01_bus_t *bus, int may_apply)
{
    for (int i = 0; i < 256; i++) {
        uint16_t st;
        if (am01_bus_read_reg(bus, CYD_REG_UART_STAT, &st) < 0)
            return;
        if (ST_RX_EMPTY(st))
            return;

        uint16_t d;
        if (am01_bus_read_reg(bus, CYD_REG_UART_DATA, &d) < 0)
            return;
        /* PRINTABLE ASCII ONLY (plus the newline handled below).
         *
         * A raw byte was stored, including 0x00 -- which terminates the line
         * early for every strcmp/at_end check downstream, so a UART framing
         * glitch delivering "CMD reboot\0<junk>" parsed as a clean,
         * argument-free reboot on a live miner. Framing glitches are exactly
         * what produce 0x00, and the FIFO even counts them. */
        char ch = (char)(d & 0xFF);
        if (ch != '\n' && ch != '\r' && (ch < 0x20 || ch == 0x7F))
            continue;

        if (ch == '\n' || ch == '\r') {
            if (g_rx.len && !g_rx.overflow) {
                g_rx.buf[g_rx.len] = '\0';
                /* The panel says one DIAG line at boot. Logged rather than
                 * dropped: it is the only way to see what the firmware did on
                 * hardware, because the case leaves only CN1 attached and the
                 * USB console unreachable. */
                if (strncmp(g_rx.buf, "DIAG ", 5) == 0)
                    fprintf(stderr, "[cyd] panel %s\n", g_rx.buf);

                cyd_cmd_t c;
                if (cyd_cmd_parse(g_rx.buf, &c) != CYD_CMD_KIND_NONE) {
                    if (may_apply) {
                        apply(&c, bus);
                    } else if (!g_deferred_valid) {
                        /* Hold ONE command until the main loop. One slot is
                         * enough: commands come from a finger on a screen,
                         * not a stream, so a second arriving inside the same
                         * ~58ms transmit window would be a double-press --
                         * and dropping that is better than queueing it. */
                        g_deferred = c;
                        g_deferred_valid = 1;
                    }
                }
                /* An unparseable line is IGNORED, not logged: a stray byte on
                 * a serial link is ordinary, and a log line per corrupted
                 * character would bury the journal. */
            }
            g_rx.len = 0;
            g_rx.overflow = 0;
        } else if (g_rx.len + 1 < sizeof g_rx.buf) {
            g_rx.buf[g_rx.len++] = ch;
        } else {
            g_rx.overflow = 1;   /* drop the line whole; resync at the newline */
            g_rx.len = 0;
        }
    }
}

/* ---- panel firmware update ---------------------------------------------
 *
 * THE UPDATE HAPPENS HERE, INSIDE THE MINER, and not in a standalone tool,
 * because libgpiod line requests are exclusive and odo-miner holds all 25
 * lines while it runs. A separate flashing process cannot open the bus
 * without the miner being stopped -- so the process that already owns the
 * link does the transfer, and mining never pauses.
 *
 * The operator stages an image with am01-panel-ota, which writes
 * CYD_OTA_IMAGE_PATH and then CYD_OTA_REQ_PATH. Seeing the .req is the
 * trigger; it is created last precisely so a half-copied image can never be
 * picked up.
 */
static int ota_write(void *ctx, const char *buf, size_t len)
{
    /* The control lines only -- there are ~1000 data chunks and logging those
     * would bury the journal. These two are the ones worth being able to
     * prove went out. */
    if (strncmp(buf, CYD_MSG_OTABEGIN, strlen(CYD_MSG_OTABEGIN)) == 0 ||
        strncmp(buf, CYD_MSG_OTAEND, strlen(CYD_MSG_OTAEND)) == 0)
        fprintf(stderr, "[cyd] ota tx: %.*s", (int)len, buf);

    int n = uart_write((am01_bus_t *)ctx, buf, len);
    if (n != (int)len)
        fprintf(stderr, "[cyd] ota tx SHORT: wrote %d of %zu\n", n, len);
    return n;
}

static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)(ts.tv_nsec / 1000000);
}

/*
 * One line from the panel, or 0 on timeout.
 *
 * Deliberately NOT drain_rx: that one parses commands and can apply them, and
 * applying a reboot in the middle of writing the panel's flash is precisely
 * the wrong moment. Here every line goes to the OTA state machine, which
 * skips what it does not recognise.
 */
static int ota_readline(void *ctx, char *buf, size_t cap, int timeout_ms)
{
    am01_bus_t *bus = (am01_bus_t *)ctx;
    uint64_t deadline = now_ms() + (uint64_t)timeout_ms;
    size_t   n = 0;

    for (;;) {
        uint16_t st;
        if (am01_bus_read_reg(bus, CYD_REG_UART_STAT, &st) < 0)
            return -1;

        if (ST_RX_EMPTY(st)) {
            if (now_ms() >= deadline)
                return 0;
            usleep(1000);
            continue;
        }

        uint16_t d;
        if (am01_bus_read_reg(bus, CYD_REG_UART_DATA, &d) < 0)
            return -1;

        char ch = (char)(d & 0xFF);
        if (ch == '\n' || ch == '\r') {
            if (n == 0)
                continue;            /* CRLF, or a blank line */
            buf[n] = '\0';
            /* Every line seen during an update is logged. An OTA is rare,
             * manual, and watched; when one fails the question is always
             * "did the panel say anything at all", and without this the
             * answer is a timeout with no evidence either way. */
            fprintf(stderr, "[cyd] ota rx: '%s'\n", buf);
            return (int)n;
        }
        /* Same printable-only rule as drain_rx: a framing glitch delivering
         * 0x00 would otherwise truncate the line for every strcmp below. */
        if (ch < 0x20 || ch == 0x7F)
            continue;
        if (n + 1 < cap)
            buf[n++] = ch;
    }
}

static void ota_progress(void *ctx, size_t done, size_t total)
{
    (void)ctx;
    static int last_pct = -1;
    int pct = total ? (int)((done * 100u) / total) : 0;
    /* Every 10%, not every chunk: there are ~1000 chunks and the journal is
     * not a progress bar. */
    if (pct / 10 != last_pct / 10) {
        last_pct = pct;
        fprintf(stderr, "[cyd] panel update %d%% (%zu/%zu)\n", pct, done, total);
    }
}

/*
 * Ship the scan result to the panel, once the helper has written it.
 *
 * POLLED, not waited on: this runs in the same thread that pushes status, and
 * blocking here would stall the display for as long as the scan takes. A scan
 * is a few seconds of radio time, so the panel is told to expect a wait and
 * this checks each pass.
 *
 * The deadline matters as much as the result. If the helper never runs -- not
 * installed, no wlan0, iw missing -- the panel must not sit on "scanning..."
 * for ever, so it is sent an empty list and can say so.
 */
static void scan_forward_if_ready(am01_bus_t *bus)
{
    if (!g_scan_wait_until)
        return;

    FILE *f = fopen(CYD_WIFI_SCAN_PATH, "r");
    if (!f) {
        if (now_ms() < g_scan_wait_until)
            return;                       /* still within the window */
        fprintf(stderr, "[cyd] wifi scan produced nothing in time\n");
        g_scan_wait_until = 0;
        uart_write(bus, CYD_MSG_SCANBEGIN "\n", strlen(CYD_MSG_SCANBEGIN) + 1);
        uart_write(bus, CYD_MSG_SCANEND "\n", strlen(CYD_MSG_SCANEND) + 1);
        return;
    }
    g_scan_wait_until = 0;

    uart_write(bus, CYD_MSG_SCANBEGIN "\n", strlen(CYD_MSG_SCANBEGIN) + 1);

    char line[256];
    int  sent = 0;
    while (sent < CYD_SCAN_MAX && fgets(line, sizeof line, f)) {
        /* "<dbm>\t<ssid>". The SSID is the rest of the line -- they may
         * contain spaces, so it is never tokenised. */
        char *tab = strchr(line, '\t');
        if (!tab)
            continue;
        *tab = '\0';
        char *ssid = tab + 1;
        char *nl = strchr(ssid, '\n');
        if (nl) *nl = '\0';
        if (!*ssid)
            continue;

        char out[CYD_LINE_MAX];
        int n = snprintf(out, sizeof out, "%s%d %s\n",
                         CYD_MSG_SCAN, (int)strtod(line, NULL), ssid);
        if (n > 0 && (size_t)n < sizeof out) {
            uart_write(bus, out, (size_t)n);
            sent++;
        }
    }
    fclose(f);
    unlink(CYD_WIFI_SCAN_PATH);

    uart_write(bus, CYD_MSG_SCANEND "\n", strlen(CYD_MSG_SCANEND) + 1);
    fprintf(stderr, "[cyd] wifi scan: %d network(s) sent to the panel\n", sent);
}

static void ota_run_if_requested(am01_bus_t *bus)
{
    struct stat st;
    if (stat(CYD_OTA_REQ_PATH, &st) != 0)
        return;

    /* Consume the request FIRST. If this update kills the panel thread or the
     * miner restarts, the image must not be retried forever. */
    unlink(CYD_OTA_REQ_PATH);

    fprintf(stderr, "[cyd] panel firmware update requested\n");

    cyd_ota_io_t io = { ota_write, ota_readline, ota_progress, bus };
    char err[256] = "";

    if (cyd_ota_send_file(CYD_OTA_IMAGE_PATH, &io, err, sizeof err) == 0) {
        fprintf(stderr, "[cyd] panel update complete; the panel is "
                        "rebooting into the new image\n");
    } else {
        /* The panel's RUNNING firmware is untouched by any failure path --
         * only the spare slot was being written. Say so, because "update
         * failed" otherwise reads as "the panel is now bricked". */
        fprintf(stderr, "[cyd] panel update FAILED: %s\n", err);
        fprintf(stderr, "[cyd] the panel is still running its previous "
                        "firmware; nothing was switched\n");
    }
    unlink(CYD_OTA_IMAGE_PATH);
}

static void *panel_thread(void *arg)
{
    am01_bus_t *bus = (am01_bus_t *)arg;
    int tick = 0;

    while (!g_stop) {
        /* Before drain_rx, so a queued command cannot be applied between the
         * request appearing and the transfer starting. */
        ota_run_if_requested(bus);
        scan_forward_if_ready(bus);

        drain_rx(bus, 1);

        /* Anything held back during a transmission runs here, where it cannot
         * splice itself into an outgoing line. */
        if (g_deferred_valid) {
            g_deferred_valid = 0;
            apply(&g_deferred, bus);
        }

        /* ---- push status, once a second ------------------------------ */
        if (++tick >= 10) {
            tick = 0;
            FILE *f = fopen(CYD_STATUS_PATH, "r");
            if (f) {
                /* THE TWO SIDES MUST AGREE ON THIS, and until now they did
                 * not. The firmware accepts CYD_LINE_MAX-1 characters before
                 * the newline (cyd_link_uart.cpp's `len + 1 < sizeof line`),
                 * and this end was emitting "STATUS " + up to CYD_LINE_MAX-1
                 * body bytes -- 1030 characters against a 1023 limit. Every
                 * line would have been discarded as an overflow.
                 *
                 * Raising CYD_LINE_MAX from 512 to 1024 did not fix that; it
                 * moved the cliff from 505 bytes of status.json to 1016. The
                 * live object is 655 bytes, so it was still latent, and the
                 * comment cheerfully anticipated the miner gaining fields --
                 * which is exactly what would have tripped it. */
                char body[CYD_STATUS_BODY_MAX + 1];
                size_t n = fread(body, 1, sizeof body - 1, f);

                /* Did it all fit? fread short-reads without complaining, so
                 * without this a status.json past the limit is shipped cut
                 * off mid-token and the panel silently shows nothing. Better
                 * to send nothing and say why, once. */
                int too_big = (n == sizeof body - 1) && (fgetc(f) != EOF);
                fclose(f);
                body[n] = '\0';

                if (too_big) {
                    static int moaned;
                    if (!moaned) {
                        moaned = 1;
                        fprintf(stderr,
                            "[cyd] status.json exceeds %d bytes; the panel "
                            "cannot be fed. Raise CYD_LINE_MAX on BOTH "
                            "sides and rebuild the firmware too.\n",
                            CYD_STATUS_BODY_MAX);
                    }
                    tick = 0;
                    usleep(100000);
                    continue;
                }

                /* status.json is pretty-printed across lines; the wire format
                 * is ONE line. Newlines become spaces rather than being
                 * stripped, so tokens cannot run together. */
                for (size_t i = 0; i < n; i++)
                    if (body[i] == '\n' || body[i] == '\r')
                        body[i] = ' ';

                char line[CYD_LINE_MAX + 16];
                int len = snprintf(line, sizeof line, "%s%s\n",
                                   CYD_MSG_STATUS, body);
                if (len > 0 && (size_t)len < sizeof line)
                    uart_write(bus, line, (size_t)len);
            }
        }

        /* SLEEP IN 1ms SLICES, DRAINING RX EACH TIME.
         *
         * This used to be one usleep(100000). The FPGA's RX FIFO is 16 bytes
         * -- 1.4ms at 115200 -- so a 100ms nap lost everything after the
         * first 16 bytes of any burst, newlines included, and the fragments
         * merged into lines nothing could parse. A command sent on its own
         * survived; one sent near anything else did not.
         *
         * 1ms keeps up with line rate (11.5 bytes/ms into a 16-byte FIFO) and
         * costs one register read per millisecond. The proper fix is a deeper
         * FIFO in uart_bridge.v, which needs a bitstream; this needs a
         * restart. */
        for (int i = 0; i < 100 && !g_stop; i++) {
            drain_rx(bus, 1);
            usleep(1000);
        }
    }
    return NULL;
}

int cyd_panel_start(void)
{
    if (g_running)
        return 0;

    am01_bus_t *bus = miner_io_gpio_bus();
    if (!bus) {
        fprintf(stderr, "[cyd] bus not open -- call after miner_io_pipe_init()\n");
        return -1;
    }

    uint16_t ver = 0;
    if (am01_bus_read_version(bus, &ver) < 0)
        return -1;
    if (ver < PANEL_MIN_VERSION) {
        /* Not an error, and said plainly: most bitstreams in service have no
         * UART, and the miner must not look broken because a panel is
         * absent. */
        fprintf(stderr, "[cyd] bitstream v%u.%u has no UART; front panel disabled\n",
                ver >> 8, ver & 0xFF);
        return -1;
    }

    /* Park the ESP32 in its run state. The RTL already defaults here, but
     * saying so explicitly costs one register write and means a panel is not
     * left in whatever state a previous run wanted. */
    am01_bus_write_reg(bus, CYD_REG_ESP_CTRL,
                       CYD_ESP_CTRL_EN | CYD_ESP_CTRL_IO0);

    g_stop = 0;
    if (pthread_create(&g_thread, NULL, panel_thread, bus) != 0) {
        fprintf(stderr, "[cyd] cannot start panel thread: %s\n", strerror(errno));
        return -1;
    }
    g_running = 1;
    fprintf(stderr, "[cyd] front panel active on the FPGA UART (JP5 15-18)\n");
    return 0;
}

void cyd_panel_stop(void)
{
    if (!g_running)
        return;
    g_stop = 1;
    pthread_join(g_thread, NULL);
    g_running = 0;
}
