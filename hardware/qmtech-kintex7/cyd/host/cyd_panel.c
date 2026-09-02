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

/* ---- UART, over the register bus -------------------------------------- */

/* Returns bytes written. SHORT WRITES ARE NORMAL and not an error: the FIFO
 * is 16 deep and drains at 11.5 kB/s, so a whole status line takes several
 * passes. The caller drops the remainder rather than blocking -- a panel that
 * misses one update gets the next one a second later, and stalling the thread
 * to guarantee delivery would be the wrong trade for a display. */
static int uart_write(am01_bus_t *bus, const char *buf, size_t len)
{
    size_t n = 0;
    while (n < len) {
        uint16_t st;
        if (am01_bus_read_reg(bus, CYD_REG_UART_STAT, &st) < 0)
            return (int)n;
        if (ST_TX_FULL(st))
            break;

        unsigned cnt = ST_TX_CNT(st);
        unsigned room = (cnt < TX_FIFO_DEPTH) ? (TX_FIFO_DEPTH - cnt) : 0;
        if (!room)
            break;

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
    int bad = (fflush(f) != 0);
    fclose(f);

    if (bad || rename(tmp, CYD_POOL_CONF_PATH) != 0) {
        fprintf(stderr, "[cyd] set_pool: failed to install %s: %s\n",
                CYD_POOL_CONF_PATH, strerror(errno));
        unlink(tmp);
        return;
    }
    /* Deliberately NOT logging the password. */
    fprintf(stderr, "[cyd] pool set to %s:%d worker %s (takes effect on restart)\n",
            c->host, c->port, c->worker);
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
    case CYD_CMD_KIND_NONE:
    default:
        break;
    }
}

/* ---- the thread -------------------------------------------------------- */

static void *panel_thread(void *arg)
{
    am01_bus_t *bus = (am01_bus_t *)arg;

    char   rx[CYD_LINE_MAX];
    size_t rxlen = 0;
    int    overflow = 0;
    int    tick = 0;

    while (!g_stop) {
        /* ---- drain RX ------------------------------------------------ */
        for (int i = 0; i < 256; i++) {
            uint16_t st;
            if (am01_bus_read_reg(bus, CYD_REG_UART_STAT, &st) < 0)
                break;
            if (ST_RX_EMPTY(st))
                break;

            uint16_t d;
            if (am01_bus_read_reg(bus, CYD_REG_UART_DATA, &d) < 0)
                break;
            char ch = (char)(d & 0xFF);

            if (ch == '\n' || ch == '\r') {
                if (rxlen && !overflow) {
                    rx[rxlen] = '\0';
                    cyd_cmd_t c;
                    if (cyd_cmd_parse(rx, &c) != CYD_CMD_KIND_NONE)
                        apply(&c, bus);
                    /* An unparseable line is IGNORED, not logged: the link
                     * carries whatever the panel says, a stray byte is
                     * ordinary, and a log line per corrupted character would
                     * bury the journal. */
                }
                rxlen = 0;
                overflow = 0;
            } else if (rxlen + 1 < sizeof rx) {
                rx[rxlen++] = ch;
            } else {
                overflow = 1;   /* drop the whole line, resync at the newline */
                rxlen = 0;
            }
        }

        /* ---- push status, once a second ------------------------------ */
        if (++tick >= 10) {
            tick = 0;
            FILE *f = fopen(CYD_STATUS_PATH, "r");
            if (f) {
                char body[CYD_LINE_MAX];
                size_t n = fread(body, 1, sizeof body - 1, f);
                fclose(f);
                body[n] = '\0';

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
