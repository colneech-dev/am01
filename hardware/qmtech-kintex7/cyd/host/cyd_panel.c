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
#include "cyd_proto.h"

#include "miner_io_gpio.h"
#include "am01_gpio_bus.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* UART_STAT at VERSION >= 0x0203:
 *   {rx_err[3:0], tx_cnt[4:0], rx_cnt[4:0], tx_full, rx_empty} */
#define ST_RX_EMPTY(v)  ((v) & 0x1u)
#define ST_TX_FULL(v)   (((v) >> 1) & 0x1u)
#define ST_TX_CNT(v)    (((v) >> 7) & 0x1Fu)
#define TX_FIFO_DEPTH   16

#define PANEL_MIN_VERSION 0x0203

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

        unsigned cnt  = ST_TX_CNT(st);
        unsigned room = ST_TX_FULL(st) ? 0
                      : (cnt < TX_FIFO_DEPTH ? TX_FIFO_DEPTH - cnt : 0);

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

static void apply_set_pool(const cyd_cmd_t *c)
{
    /* Written to a TEMPORARY and renamed, so a power cut mid-write cannot
     * leave a half-written pool config on the boot partition -- that file is
     * read by am01-miner-provision at boot, and a truncated one is a miner
     * that comes up misconfigured with no clue why. rename() within a
     * filesystem is atomic. */
    char tmp[256];
    snprintf(tmp, sizeof tmp, "%s.tmp", CYD_POOL_CONF_PATH);

    FILE *f = fopen(tmp, "w");
    if (!f) {
        fprintf(stderr, "[cyd] set_pool: cannot write %s: %s\n",
                tmp, strerror(errno));
        return;
    }
    fprintf(f, "# written by the CYD front panel\n");
    fprintf(f, "POOL_HOST=%s\n",   c->host);
    fprintf(f, "POOL_PORT=%d\n",   c->port);
    fprintf(f, "POOL_WORKER=%s\n", c->worker);
    fprintf(f, "POOL_PASS=%s\n",   c->pass);
    /* fflush pushes to the OS; fsync pushes to the DEVICE. Only the second
     * makes the rename() below meaningful: /boot is vfat on an SD card, and
     * without it a power cut can leave the directory entry renamed and the
     * data unwritten -- the exact truncated-config failure the temp-file
     * dance was supposed to prevent. Claiming power-cut safety with only an
     * fflush was worse than not claiming it.
     *
     * errno is captured BEFORE fclose(), which sets its own. */
    int bad = (fflush(f) != 0) || (fsync(fileno(f)) != 0);
    int err = errno;
    fclose(f);

    if (bad || rename(tmp, CYD_POOL_CONF_PATH) != 0) {
        fprintf(stderr, "[cyd] set_pool: failed to install %s: %s\n",
                CYD_POOL_CONF_PATH, strerror(bad ? err : errno));
        unlink(tmp);
        return;
    }
    /* Deliberately NOT logging the password. */
    fprintf(stderr, "[cyd] pool set to %s:%d worker %s (takes effect on restart)\n",
            c->host, c->port, c->worker);
}

/* Write wpa_supplicant's config and bounce the supplicant.
 *
 * Same temp-file-and-rename dance as apply_set_pool(), for the same reason: a
 * half-written config is a board that cannot join any network, and on a
 * headless miner that is a trip to fetch a keyboard.
 *
 * The file is created 0600 BEFORE anything is written to it -- creating it
 * world-readable and chmod'ing afterwards leaves a window where the PSK is
 * readable. The PSK is never logged, here or anywhere. */
static void apply_set_wifi(const cyd_cmd_t *c)
{
    char tmp[256];
    snprintf(tmp, sizeof tmp, "%s.tmp", CYD_WPA_CONF_PATH);

    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        fprintf(stderr, "[cyd] set_wifi: cannot create %s: %s\n",
                tmp, strerror(errno));
        return;
    }
    FILE *f = fdopen(fd, "w");
    if (!f) {
        fprintf(stderr, "[cyd] set_wifi: fdopen: %s\n", strerror(errno));
        close(fd);
        return;
    }
    fprintf(f, "# written by the CYD front panel\n");
    fprintf(f, "ctrl_interface=/var/run/wpa_supplicant\n");
    fprintf(f, "update_config=1\n");
    fprintf(f, "network={\n");
    fprintf(f, "\tssid=\"%s\"\n", c->ssid);
    fprintf(f, "\tpsk=\"%s\"\n", c->psk);
    fprintf(f, "}\n");

    if (fflush(f) != 0 || fsync(fileno(f)) != 0) {
        int e = errno;
        fclose(f);
        unlink(tmp);
        fprintf(stderr, "[cyd] set_wifi: flush failed: %s\n", strerror(e));
        return;
    }
    if (fclose(f) != 0) {
        fprintf(stderr, "[cyd] set_wifi: close failed: %s\n", strerror(errno));
        unlink(tmp);
        return;
    }
    if (rename(tmp, CYD_WPA_CONF_PATH) != 0) {
        fprintf(stderr, "[cyd] set_wifi: rename failed: %s\n", strerror(errno));
        unlink(tmp);
        return;
    }

    /* SSID only. The PSK is deliberately absent from the log. */
    fprintf(stderr, "[cyd] wifi configured for SSID \"%s\"\n", c->ssid);

    /* --no-block: this may be the interface carrying the ssh session that is
     * watching, and a blocking restart of the supplicant can outlive the call.
     * Failure is reported, not fatal -- the config is already on disk and will
     * be picked up at boot regardless. */
    if (system("systemctl --no-block restart wpa_supplicant@wlan0") != 0)
        fprintf(stderr, "[cyd] set_wifi: could not restart the supplicant; "
                        "the config will apply at next boot\n");
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
        /* The panel already required a CONFIRM screen for this -- two touches,
         * proved by test_cyd_ui.c's exhaustive sweep. Logged loudly because a
         * miner that reboots itself with no explanation in the journal is a
         * genuinely nasty thing to debug. */
        fprintf(stderr, "[cyd] REBOOT requested from the front panel\n");
        sync();
        if (system("systemctl reboot") != 0)
            fprintf(stderr, "[cyd] reboot command failed\n");
        break;
    case CYD_CMD_KIND_SET_POOL:
        apply_set_pool(c);
        break;
    case CYD_CMD_KIND_RESTART:
        /* Restarting the miner means restarting the process this thread lives
         * in. --no-block is not optional: a blocking `systemctl restart` on
         * one's own unit waits for a stop that cannot complete until this call
         * returns. Queue the job and let systemd do it. */
        fprintf(stderr, "[cyd] miner restart requested from the front panel\n");
        if (system("systemctl --no-block restart odo-miner") != 0)
            fprintf(stderr, "[cyd] restart command failed\n");
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
        char ch = (char)(d & 0xFF);

        if (ch == '\n' || ch == '\r') {
            if (g_rx.len && !g_rx.overflow) {
                g_rx.buf[g_rx.len] = '\0';
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

static void *panel_thread(void *arg)
{
    am01_bus_t *bus = (am01_bus_t *)arg;
    int tick = 0;

    while (!g_stop) {
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

        usleep(100000);   /* 10 Hz: responsive to touch, cheap on the bus */
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
