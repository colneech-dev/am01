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
#include <fcntl.h>
#include <signal.h>
#include <termios.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

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

/* Where the PTY appears. A stable name, because the real /dev/pts/N changes
 * every run and no script should have to discover it. */
#define CYD_PTY_LINK "/dev/am01-cyd"

static volatile sig_atomic_t g_pty_stop;
static void pty_sig(int sig) { (void)sig; g_pty_stop = 1; }

/* Shuttle bytes between a PTY and the FPGA UART until interrupted.
 *
 * enter_boot drives the EN/IO0 sequence first. esptool cannot do it itself
 * here: it normally toggles DTR/RTS, and a PTY has no modem-control lines,
 * which is why every invocation below needs --before no_reset. */
static int pty_bridge(int enter_boot)
{
    if (uart_open_bus() < 0)
        return 1;

    if (enter_boot) {
        printf("driving EN/IO0 to enter the ROM bootloader...\n");
        fflush(stdout);
        if (esp_enter_bootloader() < 0) {
            fprintf(stderr, "ESP_CTRL write failed: %s\n", strerror(errno));
            uart_close_bus();
            return 1;
        }
        /* The ROM needs a moment before it will answer a sync. */
        usleep(200000);
    }

    int m = posix_openpt(O_RDWR | O_NOCTTY);
    if (m < 0 || grantpt(m) < 0 || unlockpt(m) < 0) {
        fprintf(stderr, "cannot create a PTY: %s\n", strerror(errno));
        uart_close_bus();
        return 1;
    }
    const char *slave = ptsname(m);
    if (!slave) {
        fprintf(stderr, "ptsname failed: %s\n", strerror(errno));
        close(m);
        uart_close_bus();
        return 1;
    }

    unlink(CYD_PTY_LINK);
    if (symlink(slave, CYD_PTY_LINK) < 0)
        fprintf(stderr, "warning: cannot create %s: %s -- use %s directly\n",
                CYD_PTY_LINK, strerror(errno), slave);

    printf("\nPTY ready:  %s  ->  %s\n\n", CYD_PTY_LINK, slave);
    printf("  esptool --chip esp32 --port %s --baud 115200 \\\n",
           CYD_PTY_LINK);
    printf("          --before no_reset --after no_reset \\\n");
    printf("          write_flash 0x10000 firmware.bin\n\n");
    printf("--before no_reset is REQUIRED: a PTY has no DTR/RTS, so this\n");
    printf("daemon has already put the chip in the bootloader for you.\n");
    printf("Ctrl-C when done.\n\n");
    fflush(stdout);

    fcntl(m, F_SETFL, O_NONBLOCK);
    signal(SIGINT, pty_sig);
    signal(SIGTERM, pty_sig);

    unsigned long to_esp = 0, from_esp = 0;
    while (!g_pty_stop) {
        uint8_t buf[256];
        int busy = 0;

        /* host -> ESP32 */
        int n = (int)read(m, buf, sizeof buf);
        if (n > 0) {
            int w = uart_tx(buf, (size_t)n);
            if (w > 0) to_esp += (unsigned long)w;
            /* A short write means the FIFO stayed full for ~2s, which on a
             * link this slow means the far end has stopped listening. Say so
             * rather than silently truncating a firmware image. */
            if (w != n)
                fprintf(stderr, "\nWARNING: %d of %d bytes sent\n", w, n);
            busy = 1;
        }
        /* EIO here just means no process has the slave open yet. */

        /* ESP32 -> host */
        int r = uart_rx(buf, sizeof buf);
        if (r > 0) {
            ssize_t unused = write(m, buf, (size_t)r);
            (void)unused;
            from_esp += (unsigned long)r;
            busy = 1;
        }

        if (!busy)
            usleep(500);
    }

    printf("\nbridge closed: %lu bytes to the panel, %lu back\n",
           to_esp, from_esp);
    unlink(CYD_PTY_LINK);
    close(m);
    uart_close_bus();
    return 0;
}

/* Serve the FPGA UART on a TCP port.
 *
 * The board has no esptool and no python3 -- it is a minimal Buildroot image
 * -- so the PTY cannot be driven locally. esptool understands pyserial's
 * socket:// URL, so this lets esptool run on the PC and reach the panel
 * through the Pi, with nothing extra installed on the miner.
 *
 * TCP_NODELAY matters here: esptool's sync is a request/response handshake
 * with short packets, and Nagle would coalesce them into timeouts. */
static int tcp_bridge(int port, int enter_boot)
{
    if (uart_open_bus() < 0)
        return 1;

    int ls = socket(AF_INET, SOCK_STREAM, 0);
    if (ls < 0) {
        fprintf(stderr, "socket: %s\n", strerror(errno));
        uart_close_bus(); return 1;
    }
    int one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);

    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    a.sin_port = htons((uint16_t)port);
    if (bind(ls, (struct sockaddr *)&a, sizeof a) < 0 || listen(ls, 1) < 0) {
        fprintf(stderr, "bind/listen on %d: %s\n", port, strerror(errno));
        close(ls); uart_close_bus(); return 1;
    }

    printf("UART served on TCP %d. From the PC:\n\n", port);
    printf("  esptool --chip esp32 --port socket://<pi-ip>:%d \\\n", port);
    printf("          --before no_reset --after no_reset \\\n");
    printf("          write_flash 0x1000 bootloader.bin 0x8000 partitions.bin \\\n");
    printf("          0xe000 boot_app0.bin 0x10000 firmware.bin\n\n");
    printf("waiting for a connection (Ctrl-C to stop)...\n");
    fflush(stdout);

    signal(SIGINT, pty_sig);
    signal(SIGTERM, pty_sig);

    int cs = accept(ls, NULL, NULL);
    if (cs < 0) {
        fprintf(stderr, "accept: %s\n", strerror(errno));
        close(ls); uart_close_bus(); return 1;
    }
    setsockopt(cs, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    fcntl(cs, F_SETFL, O_NONBLOCK);
    printf("connected\n"); fflush(stdout);

    /* Bootloader entry AFTER the client connects, so the ROM is freshly in
     * download mode when esptool starts syncing rather than having sat there
     * while somebody typed a command. */
    if (enter_boot) {
        printf("driving EN/IO0 into the ROM bootloader...\n");
        fflush(stdout);
        esp_enter_bootloader();
        usleep(200000);
    }

    unsigned long tx = 0, rx = 0;
    while (!g_pty_stop) {
        uint8_t buf[256];
        int busy = 0;

        int n = (int)recv(cs, buf, sizeof buf, 0);
        if (n == 0) { printf("\nclient closed\n"); break; }
        if (n > 0) {
            int w = uart_tx(buf, (size_t)n);
            if (w > 0) tx += (unsigned long)w;
            if (w != n)
                fprintf(stderr, "\nWARNING: %d of %d bytes sent\n", w, n);
            busy = 1;
        }

        int r = uart_rx(buf, sizeof buf);
        if (r > 0) {
            ssize_t u = send(cs, buf, (size_t)r, MSG_NOSIGNAL);
            (void)u;
            rx += (unsigned long)r;
            busy = 1;
        }

        if (!busy)
            usleep(300);
    }

    printf("\nclosed: %lu bytes to the panel, %lu back\n", tx, rx);
    close(cs); close(ls); uart_close_bus();
    return 0;
}

int main(int argc, char **argv)
{
    /* Set by whichever subcommand ran; declared here because the
     * `reset` path jumps into the listen body. */
    int listen_secs = 30;


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

    /* `txstream [secs]` -- transmit continuously so the TX line can be
     * METERED. A UART idles high, so an idle line and a dead line both
     * read 3.3V; only sustained traffic tells them apart. Sending 0x55
     * (01010101) gives the maximum toggle rate, so a DMM should read
     * roughly half scale -- around 1.6-2.5V depending on how it
     * averages. Still 3.3V means the pin is not switching at all. */
    if (argc > 1 && strcmp(argv[1], "txstream") == 0) {
        if (uart_open_bus() < 0)
            return 1;
        int secs = (argc > 2) ? atoi(argv[2]) : 30;
        printf("transmitting 0x55 continuously for %ds -- measure now\n", secs);
        printf("  JP5 15 and the ESP32 RX pin should BOTH drop well below 3.3V\n");
        fflush(stdout);
        time_t end = time(NULL) + secs;
        unsigned long sent = 0;
        uint8_t pat[32];
        memset(pat, 0x55, sizeof pat);
        while (time(NULL) < end) {
            int w = uart_tx(pat, sizeof pat);
            if (w > 0) sent += (unsigned long)w;
        }
        printf("sent %lu bytes\n", sent);
        uart_close_bus();
        return 0;
    }

    /* `tcp [port] [run]` -- serve the UART over TCP for a remote esptool. */
    if (argc > 1 && strcmp(argv[1], "tcp") == 0) {
        int port = (argc > 2) ? atoi(argv[2]) : 2323;
        int boot = !(argc > 3 && strcmp(argv[3], "run") == 0);
        return tcp_bridge(port, boot);
    }

    /* `pty [run]` -- expose the FPGA UART as /dev/am01-cyd for esptool.
     *
     * Default enters the ROM bootloader first, which is what you want for
     * flashing. `pty run` skips that and leaves the panel running, for
     * watching its normal output. */
    if (argc > 1 && strcmp(argv[1], "pty") == 0) {
        int boot = !(argc > 2 && strcmp(argv[2], "run") == 0);
        return pty_bridge(boot);
    }

    /* `txtest` -- one host write must queue exactly ONE byte.
     *
     * The on-hardware check for the S_WRITE one-shot defect: the bus FSM
     * re-runs its case every cycle until WR_N is released, so before the fix
     * a single write to ADDR_UART_DATA pushed the byte 4-16 times.
     *
     * ONE PROCESS, and that is the whole point. Doing this with am01_reg from
     * a shell leaves ~50ms between the write and the status read, and even 16
     * duplicated bytes drain in 1.4ms at 115200 -- so the shell reports
     * tx_cnt 0 and everything looks fine whether the RTL is broken or not.
     *
     * Writes 8 bytes back to back so the FIFO cannot drain between them:
     * correct RTL leaves ~7 queued (one already in the shifter), the broken
     * one saturates at 16 with tx_full set. */
    if (argc > 1 && strcmp(argv[1], "txtest") == 0) {
        if (uart_open_bus() < 0)
            return 1;

        uint16_t st = 0;
        am01_bus_read_reg(g_bus, CYD_REG_UART_STAT, &st);
        printf("before:  tx_cnt=%u tx_full=%u\n",
               ST_TX_CNT(st), ST_TX_FULL(st));

        for (int i = 0; i < 8; i++)
            am01_bus_write_reg(g_bus, CYD_REG_UART_DATA, (uint16_t)(0x41 + i));

        am01_bus_read_reg(g_bus, CYD_REG_UART_STAT, &st);
        unsigned cnt = ST_TX_CNT(st), full = ST_TX_FULL(st);
        printf("after 8 writes: tx_cnt=%u tx_full=%u\n", cnt, full);

        if (full || cnt > 12) {
            printf("FAIL: the FIFO is saturated -- each write is being pushed\n"
                   "      many times. This bitstream has the S_WRITE one-shot\n"
                   "      defect; flash one built after the fix.\n");
            uart_close_bus();
            return 1;
        }
        if (cnt >= 4 && cnt <= 8) {
            printf("PASS: 8 writes queued %u bytes -- one push per write.\n", cnt);
            uart_close_bus();
            return 0;
        }
        printf("INCONCLUSIVE: tx_cnt=%u. Expected 4-8 for correct RTL.\n", cnt);
        uart_close_bus();
        return 1;
    }

    /* `listen` -- dump whatever arrives on the FPGA UART, as fast as the bus
     * allows. Diagnostic, not part of the panel path.
     *
     * Exists because polling with am01_reg from a shell spawns a process per
     * byte -- about 10 reads a second against a 16-byte FIFO that a 115200
     * boot banner fills in 17ms. It sees nothing and proves nothing. This
     * reads in a tight loop and prints raw hex plus the printable form, so a
     * wrong baud (garbage bytes) looks different from a dead wire (none). */
    /* `reset [secs]` -- pulse EN, then capture what the ESP32 says on the way
     * back up. THE DIRECT TEST OF THE cyd_esp_en WIRE (JP5 17).
     *
     * Must be one process: the GPIO bus is exclusive, so resetting with
     * am01_reg and listening with a separate tool cannot overlap and the
     * banner is always missed.
     *
     * What a WORKING EN line looks like: the ROM bootloader speaks first at
     * 74880 baud, which necessarily frame-errors at 115200 and appears as
     * garbage, and only then does the application banner arrive cleanly.
     * Garbage followed by readable text means the chip really restarted.
     * Only touch output, with no banner, means EN never took. */
    /* `boot [secs]` -- enter the ROM bootloader, then READ THE BANNER BACK.
     *
     * The test that should have come first. The ROM prints "ets Jul 29 2019"
     * on EVERY reset, in every mode, so seeing it proves only that EN works.
     * The mode is in the NEXT line:
     *
     *   boot:0x13 (SPI_FAST_FLASH_BOOT)  -- normal. IO0 DID NOT TAKE.
     *   boot:0x03 / 0x07 (DOWNLOAD_BOOT) -- in the bootloader, flashable.
     *
     * Mistaking the banner for proof of download mode sent the whole
     * investigation at the TX wire, which measured and simulated perfect,
     * while the chip may simply have been running the app and ignoring
     * esptool exactly as a running app should. */
    if (argc > 1 && strcmp(argv[1], "boot") == 0) {
        if (uart_open_bus() < 0)
            return 1;
        printf("EN low, IO0 low, release -- then reading the mode back\n");
        fflush(stdout);
        if (esp_enter_bootloader() < 0) {
            fprintf(stderr, "ESP_CTRL write failed: %s\n", strerror(errno));
            uart_close_bus();
            return 1;
        }
        listen_secs = (argc > 2) ? atoi(argv[2]) : 6;
        goto do_listen;
    }

    if (argc > 1 && strcmp(argv[1], "reset") == 0) {
        if (uart_open_bus() < 0)
            return 1;
        printf("pulsing EN low then releasing...\n");
        fflush(stdout);
        if (esp_reset_run() < 0) {
            fprintf(stderr, "ESP_CTRL write failed: %s\n", strerror(errno));
            uart_close_bus();
            return 1;
        }
        listen_secs = (argc > 2) ? atoi(argv[2]) : 10;
        goto do_listen;
    }

    if (argc > 1 && strcmp(argv[1], "listen") == 0) {
        if (uart_open_bus() < 0)
            return 1;
        listen_secs = (argc > 2) ? atoi(argv[2]) : 30;
do_listen:
        {
        int secs = listen_secs;
        printf("listening for %ds -- touch the panel or reset it\n", secs);
        fflush(stdout);

        time_t end = time(NULL) + secs;
        unsigned long total = 0;
        int col = 0;
        while (time(NULL) < end) {
            uint8_t b[64];
            int n = uart_rx(b, sizeof b);
            if (n <= 0) { usleep(2000); continue; }
            for (int i = 0; i < n; i++) {
                if (b[i] >= 32 && b[i] < 127)
                    printf("%02x(%c) ", b[i], b[i]);
                else
                    printf("%02x    ", b[i]);
                if (++col % 12 == 0)
                    printf("\n");
            }
            total += n;
            fflush(stdout);
        }

        uint16_t st = 0;
        am01_bus_read_reg(g_bus, CYD_REG_UART_STAT, &st);
        printf("\n--- %lu byte(s). UART_STAT 0x%04x rx_err=%u ---\n",
               total, st, ST_RX_ERR(st));
        if (total == 0)
            printf("NOTHING ARRIVED: either the CYD is not transmitting, or its\n"
                   "TX is not reaching JP5 16. Swapping the two data wires is\n"
                   "the cheapest next test.\n");
        uart_close_bus();
        return total ? 0 : 1;
        }
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
