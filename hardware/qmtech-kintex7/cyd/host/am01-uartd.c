/*
 * am01-uartd -- bridge the FPGA-hosted UART to a PTY, and to the CYD panel.
 *
 * The register accessors are REAL as of 2026-09-01 -- hdl/uart_bridge.v is
 * instantiated on JP5 15-18 and a bitstream reporting VERSION >= 0x0202 has
 * it. The protocol/PTY layers above them are still scaffolding. Nothing here
 * touches the existing ILI9341 path.
 *
 * TWO CONSTRAINTS FOUND WHILE WIRING THE ACCESSORS UP, both worth knowing
 * before trusting this:
 *
 * 1. THE BUS CANNOT BE SHARED BETWEEN PROCESSES. libgpiod line requests are
 *    exclusive, and odo-miner holds all 25 lines while it runs. So this
 *    daemon cannot open the bus alongside the miner -- it must be run with
 *    the miner STOPPED, which is fine for flashing (you are updating the
 *    panel) but is not a design for the normal once-a-second status push.
 *    That wants folding into odo-miner as a thread instead; the bus mutex
 *    added in 5413a04 is what makes that safe.
 *
 * 2. UART_STAT CANNOT REPORT A FULL TX FIFO. Its layout is
 *    {rx_err[7:0], rx_cnt[3:0], tx_cnt[2:0], rx_empty} -- and the TX FIFO is
 *    16 deep, so a 5-bit count is truncated to 3 bits and depths 0, 8 and 16
 *    are indistinguishable. There is no tx_full bit. The RTL drops a write
 *    into a full FIFO silently and its own comment says "the host can read
 *    UART_STAT first", which UART_STAT cannot actually answer.
 *
 *    uart_tx() works around it exactly rather than approximately: never let
 *    more than 7 bytes be outstanding, so tx_cnt[2:0] == 0 is unambiguous.
 *    That costs nothing -- 7 bytes at 115200 baud is 608us, which is line
 *    rate -- so the workaround is not even slow. Worth fixing in RTL anyway,
 *    next time the register map is touched.
 *
 * TWO JOBS, one link:
 *
 *   1. PANEL MODE (normal): push /run/odod/status.json to the panel once a
 *      second, and apply the commands it sends back.
 *
 *   2. FLASH MODE: expose the UART as a PTY so STOCK esptool can reprogram the
 *      ESP32 over the same four wires, with no cable and without taking the
 *      panel out of the case:
 *
 *          esptool --port /dev/am01-cyd --before no_reset write_flash 0x0 fw.bin
 *
 *      This is the piece that makes the whole approach maintainable. Without
 *      it, every firmware change means physical access. esptool wants a tty
 *      and the FPGA offers a register interface, so a PTY is the adapter --
 *      and using a PTY rather than reimplementing the esptool protocol means
 *      the flashing path is code nobody here has to own.
 *
 * WHY A DAEMON AND NOT A KERNEL DRIVER: the register bus is already driven
 * from userspace by libgpiod (am01_gpio_bus.c), the traffic is a status line a
 * second, and a userspace bug is a restart rather than a kernel oops on a
 * headless miner.
 */

#define _POSIX_C_SOURCE 200809L
/* usleep() is obsolescent and _POSIX_C_SOURCE alone hides it. The rest of
 * this tree compiles with both (see sw/Makefile), so match that rather
 * than open-coding nanosleep here. */
#define _DEFAULT_SOURCE

#include "cyd_proto.h"
#include "am01_gpio_bus.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>

/* ------------------------------------------------------------------ */
/* FPGA UART access, over the same register bus the miner uses.         */
/* ------------------------------------------------------------------ */

static am01_bus_t *g_bus;

/* UART_STAT layout at VERSION >= 0x0203, from odocrypt_gpio_wrapper.v:
 *   {rx_err[3:0], tx_cnt[4:0], rx_cnt[4:0], tx_full, rx_empty}
 *
 * The 0x0202 layout could not report a full TX FIFO -- see the banner. Both
 * counts are now exact and there is a real tx_full, so uart_tx() fills the
 * available room in one go instead of creeping along in 7-byte bursts with a
 * full drain between each. */
#define ST_RX_EMPTY(v)  ((v) & 0x1u)
#define ST_TX_FULL(v)   (((v) >> 1) & 0x1u)
#define ST_RX_CNT(v)    (((v) >> 2) & 0x1Fu)
#define ST_TX_CNT(v)    (((v) >> 7) & 0x1Fu)
#define ST_RX_ERR(v)    (((v) >> 12) & 0xFu)

/* uart_bridge.v is instantiated with FIFO_AW=4. */
#define TX_FIFO_DEPTH 16

int uart_open_bus(void)
{
    g_bus = am01_bus_open(NULL);
    if (!g_bus) {
        fprintf(stderr, "am01-uartd: cannot open the GPIO bus: %s\n",
                strerror(errno));
        fprintf(stderr, "            odo-miner holds these lines while it runs;"
                        " stop it first.\n");
        return -1;
    }

    uint16_t ver = 0;
    if (am01_bus_read_version(g_bus, &ver) < 0) {
        fprintf(stderr, "am01-uartd: cannot read VERSION: %s\n", strerror(errno));
        am01_bus_close(g_bus); g_bus = NULL;
        return -1;
    }
    /* REFUSE rather than read zeros back from unmapped addresses and report a
     * dead panel. That distinction is the whole reason 0x0202 exists. */
    /* 0x0203, not 0x0202. A 0x0202 bitstream HAS a UART, but UART_STAT's
     * fields sit in different places and it cannot report a full TX FIFO,
     * so this would misread every field and silently drop bytes. Refusing
     * is the only safe answer; 0x0202 never reached a board anyway. */
    if (ver < 0x0203) {
        fprintf(stderr, "am01-uartd: bitstream is v%u.%u -- needs >= v2.3 "
                        "(v2.2's UART_STAT cannot report a full TX FIFO).\n",
                ver >> 8, ver & 0xFF);
        am01_bus_close(g_bus); g_bus = NULL;
        return -1;
    }
    return 0;
}

void uart_close_bus(void)
{
    if (g_bus) { am01_bus_close(g_bus); g_bus = NULL; }
}

/* Returns bytes read, 0 if none pending, -1 on error. */
static int uart_rx(uint8_t *buf, size_t max)
{
    if (!g_bus) { errno = ENOTCONN; return -1; }

    size_t n = 0;
    while (n < max) {
        uint16_t st;
        if (am01_bus_read_reg(g_bus, CYD_REG_UART_STAT, &st) < 0)
            return n ? (int)n : -1;
        if (ST_RX_EMPTY(st))
            break;

        uint16_t d;
        if (am01_bus_read_reg(g_bus, CYD_REG_UART_DATA, &d) < 0)
            return n ? (int)n : -1;
        buf[n++] = (uint8_t)(d & 0xFF);
    }
    return (int)n;
}

/* Returns bytes written, -1 on error. A SHORT WRITE IS NORMAL -- the caller
 * must resume from where this stopped. */
static int uart_tx(const uint8_t *buf, size_t len)
{
    if (!g_bus) { errno = ENOTCONN; return -1; }

    size_t n = 0;
    while (n < len) {
        /* Ask how much room there is, and fill it. Bounded so a dead link
         * cannot wedge the daemon: at 115200 a full 16-byte FIFO drains in
         * 1.4ms, so 200 polls at 100us is orders of magnitude of headroom. */
        uint16_t st = 0;
        unsigned room = 0;
        int spins = 0;
        for (;;) {
            if (am01_bus_read_reg(g_bus, CYD_REG_UART_STAT, &st) < 0)
                return n ? (int)n : -1;
            if (!ST_TX_FULL(st)) {
                unsigned cnt = ST_TX_CNT(st);
                room = (cnt < TX_FIFO_DEPTH) ? (TX_FIFO_DEPTH - cnt) : 0;
                if (room)
                    break;
            }
            if (++spins > 200) {
                errno = ETIMEDOUT;
                return n ? (int)n : -1;
            }
            usleep(100);
        }

        size_t burst = len - n;
        if (burst > room)
            burst = room;

        for (size_t i = 0; i < burst; i++) {
            if (am01_bus_write_reg(g_bus, CYD_REG_UART_DATA, buf[n]) < 0)
                return n ? (int)n : -1;
            n++;
        }
    }
    return (int)n;
}

/* Drive the ESP32's EN/IO0. The reset-into-bootloader sequence lives HERE, in
 * software, precisely so it can be adjusted without a bitstream rebuild --
 * module-to-module timing differences are common and a 1h35m turnaround to
 * chase one would be absurd. */
static int esp_ctrl(int en, int io0)
{
    if (!g_bus) { errno = ENOTCONN; return -1; }

    uint16_t v = (uint16_t)((en ? CYD_ESP_CTRL_EN : 0) |
                            (io0 ? CYD_ESP_CTRL_IO0 : 0));
    return am01_bus_write_reg(g_bus, CYD_REG_ESP_CTRL, v);
}

/* Hold IO0 low across a reset, which is how the ESP32 ROM enters its serial
 * bootloader. Timings are the conventional esptool ones and are here, in
 * software, for exactly the reason above.
 *
 * EN is active LOW: pulling it low resets the chip. */
int esp_enter_bootloader(void)
{
    /* esp_ctrl(en, io0): 1 drives the pin HIGH.
     *
     * EN  low  = held in reset.        EN  high = running.
     * IO0 low  = ROM download mode.    IO0 high = boot from flash.
     *
     * The ROM samples IO0 on the RISING edge of EN, so IO0 must already be
     * low before reset is released and must stay low across it.
     *
     * THIS SEQUENCE WAS INVERTED until 2026-09-01: it passed io0=1 under
     * comments saying "IO0 low", so it would have reset the chip straight
     * back into normal boot and never reached the bootloader. */
    if (esp_ctrl(0, 0) < 0) return -1;   /* EN low: reset. IO0 low: select ROM */
    usleep(100000);
    if (esp_ctrl(1, 0) < 0) return -1;   /* release EN with IO0 STILL low */
    usleep(50000);
    return esp_ctrl(1, 1);               /* IO0 back high; the ROM has latched */
}

int esp_reset_run(void)
{
    /* IO0 HIGH throughout, so the ROM boots from flash. Passing io0=0 here --
     * as this did before 2026-09-01 -- drops it into download mode instead,
     * which presents as a panel that resets and then shows nothing. */
    if (esp_ctrl(0, 1) < 0) return -1;   /* EN low: reset, IO0 high */
    usleep(100000);
    return esp_ctrl(1, 1);               /* release: normal boot */
}

/* ------------------------------------------------------------------ */
/* Status push                                                         */
/* ------------------------------------------------------------------ */

/* The payload is passed through VERBATIM -- this deliberately does not parse
 * or re-encode it. The panel reads the same object odo-webd and odo-ui do, so
 * it cannot drift from them, and a new miner field needs no change here. */
static int push_status(void)
{
    FILE *f = fopen(CYD_STATUS_PATH, "r");
    if (!f)
        return -1;   /* miner not running yet; the panel shows MINER DOWN */

    char json[CYD_LINE_MAX];
    size_t n = fread(json, 1, sizeof(json) - 1, f);
    fclose(f);
    if (n == 0)
        return -1;
    json[n] = '\0';

    /* Strip newlines: the protocol is line-oriented, and status.json is
     * pretty-printed. A single embedded newline would split one message into
     * several and desynchronise the panel -- the kind of fault that presents
     * as "the display is occasionally garbage" and takes a day to find. */
    for (size_t i = 0; i < n; i++)
        if (json[i] == '\n' || json[i] == '\r')
            json[i] = ' ';

    char line[CYD_LINE_MAX + 16];
    int len = snprintf(line, sizeof(line), "%s%s\n", CYD_MSG_STATUS, json);
    if (len <= 0 || (size_t)len >= sizeof(line))
        return -1;   /* refuse to send a truncated, unparseable object */

    return uart_tx((const uint8_t *)line, (size_t)len);
}

/* ------------------------------------------------------------------ */
/* Commands from the panel                                             */
/* ------------------------------------------------------------------ */

static int touch_flag(const char *path, int on)
{
    if (!on)
        return unlink(path) == 0 || errno == ENOENT ? 0 : -1;
    FILE *f = fopen(path, "w");
    if (!f) return -1;
    fclose(f);
    return 0;
}

/* Every command lands on something that ALREADY EXISTS. Nothing here invents a
 * new control surface: fan_boost and reset_stats are the flag files odo-webd
 * already watches, and a pool change is written to the boot-partition config
 * that am01-miner-provision.service installs -- so it survives a reflash, and
 * it survives in the one place that is already authoritative for it. */
static int handle_cmd(const char *line)
{
    const char *p = line + strlen(CYD_CMD_PREFIX);

    if (!strncmp(p, CYD_CMD_FAN_BOOST, strlen(CYD_CMD_FAN_BOOST)))
        return touch_flag(CYD_FAN_BOOST_PATH,
                          strstr(p, " 1") != NULL);

    if (!strncmp(p, CYD_CMD_RESET_STAT, strlen(CYD_CMD_RESET_STAT)))
        return touch_flag(CYD_RESET_STAT_PATH, 1);

    if (!strncmp(p, CYD_CMD_REBOOT, strlen(CYD_CMD_REBOOT))) {
        /* TODO: confirm-guard this at the protocol level too. odo-ui already
         * puts a CONFIRM REBOOT step in front of it on the panel, but a link
         * that can reboot the miner on one malformed line is a link that will
         * eventually do so. */
        return -1;
    }

    if (!strncmp(p, CYD_CMD_SET_POOL, strlen(CYD_CMD_SET_POOL))) {
        /* TODO: write DAEMON_OPTS into CYD_POOL_CONF_PATH, then
         * `systemctl restart am01-miner-provision odo-miner`. Must validate
         * before writing: am01-miner-provision refuses a file with no
         * DAEMON_OPTS or with placeholders still in it, and silently writing
         * something it will refuse would look like the panel doing nothing. */
        return -1;
    }

    return -1;
}

int main(int argc, char **argv)
{

    /* `selftest` is all that is wired up so far, and it is deliberately the
     * first thing built: it answers "is there a UART in this bitstream and
     * does a byte come back" without a CYD attached at all, by looping TX to
     * RX. Wire JP5 15 to JP5 16 and run it. Everything above this -- the PTY,
     * the status push -- is worth nothing until that passes. */
    if (argc > 1 && strcmp(argv[1], "selftest") == 0) {
        if (uart_open_bus() < 0)
            return 1;

        static const uint8_t pat[] = "AM01-CYD-LOOPBACK-0123456789";
        const size_t n = sizeof(pat) - 1;

        int w = uart_tx(pat, n);
        printf("tx: %d of %zu bytes\n", w, n);

        /* One byte at 115200 is 87us; allow generously for the whole burst. */
        usleep(20000 + n * 200);

        uint8_t got[64] = {0};
        int r = uart_rx(got, sizeof(got) - 1);
        printf("rx: %d bytes: \"%s\"\n", r, got);

        uint16_t st = 0;
        am01_bus_read_reg(g_bus, CYD_REG_UART_STAT, &st);
        printf("UART_STAT 0x%04x  rx_err=%u rx_cnt=%u tx_cnt=%u "
               "tx_full=%u rx_empty=%u\n",
               st, ST_RX_ERR(st), ST_RX_CNT(st), ST_TX_CNT(st),
               ST_TX_FULL(st), ST_RX_EMPTY(st));

        int ok = (w == (int)n) && (r == (int)n) && memcmp(pat, got, n) == 0;
        printf("%s\n", ok ? "LOOPBACK OK" : "LOOPBACK FAILED "
               "(is JP5 15 wired to JP5 16?)");
        uart_close_bus();
        return ok ? 0 : 1;
    }

    fprintf(stderr,
        "am01-uartd: the register accessors are implemented; the PTY and\n"
        "            status-push layers are not. Usable command:\n"
        "              am01-uartd selftest   (loop JP5 15 -> 16 first)\n"
        "            Requires a v2.2+ bitstream and odo-miner STOPPED --\n"
        "            libgpiod line requests are exclusive.\n");

    (void)push_status; (void)handle_cmd;
    (void)esp_enter_bootloader; (void)esp_reset_run;
    return 1;
}
