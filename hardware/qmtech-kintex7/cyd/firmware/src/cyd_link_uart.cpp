/*
 * cyd_link_uart.cpp -- the link to the miner, over the FPGA-hosted UART.
 *
 * DELIBERATELY THIN. All it does is collect newline-terminated lines and hand
 * STATUS payloads to cyd_status_parse() (28 checks, run on a PC against the
 * miner's real status.json). Parsing is where a silent misread becomes a
 * confidently wrong display, so none of it lives in here where it could only
 * be tested on hardware.
 *
 * ---------------------------------------------------------------------------
 * IT USES Serial2 ON CN1 (GPIO27 RX, GPIO22 TX). NOT UART0, AND NOT P5.
 * ---------------------------------------------------------------------------
 * This was UART0 over P5, and UART0 CANNOT WORK for the inbound direction on
 * this board. P5's TX/RX reach GPIO1/GPIO3 through 100 ohm series resistors
 * (R5/R6) while the onboard CH340C sits DIRECTLY on those same two GPIOs. An
 * external driver therefore reaches GPIO3 only through 100 ohms and loses the
 * divider against the CH340's powered push-pull output: GPIO3 sits near 2.4V
 * while the far end asserts a zero, against a 0.825V threshold. The chip reads
 * a permanent 1.
 *
 * Measured, not assumed: the FPGA transmits conformant RS-232 at line rate
 * from a pin proved by loopback, the wires are proved end to end, and the
 * ESP32 sits in DOWNLOAD_BOOT saying "waiting for download" -- and never
 * answers. Two different panels behaved identically, because it is the board
 * design. Outbound works because GPIO1 is an OUTPUT driving through R5 into a
 * high-impedance input, where 100 ohms costs nothing. See docs/JP5-WIRING.md.
 *
 * No amount of drive strength fixes it. Even a zero-impedance driver through
 * R6 leaves GPIO3 at 2.2V, and even replacing R6 with a 0R link leaves 1.24V.
 * The only cure on UART0 is removing the CH340, which costs USB flashing.
 *
 * CN1 carries GND, IO22, IO27, 3V3 and the CH340 touches none of it. GPIO22
 * and GPIO27 are free on this board -- the display uses 2/12/13/14/15/21, touch
 * uses 25/32/33/36/39, the SD card uses 5/18/19/23, and the RGB LED uses 4/16/17.
 *
 * NOTE the RGB LED on 16/17: those are Serial2's DEFAULT pins, so begin() MUST
 * be given explicit pins or the link would drive the LED and nothing else.
 *
 * Two consequences of the move, both improvements:
 *
 *   1. USB and the link no longer share a pair, so the USB console is free
 *      again -- and it is how the panel gets flashed.
 *   2. Serial.print() debugging is safe once more: it goes to USB, not down
 *      the link. This file still emits nothing uninvited, because the daemon
 *      would have to skip it, but a stray print is no longer a wire fault.
 *
 * The protocol is line-oriented text (see ../host/cyd_proto.h), which is what
 * makes that tolerable at all -- a binary framing would desynchronise on the
 * first stray byte.
 */

#include <Arduino.h>

#include "cyd_link.h"
#include "cyd_ota.h"
#include "cyd_status_parse.h"

/* CN1's two free GPIOs. Explicit because Serial2 would otherwise default to
 * GPIO16/17, which are the RGB LED. */
#define CYD_LINK_RX_PIN 27
#define CYD_LINK_TX_PIN 22

/* One name for the port, so the choice lives in exactly one place. */
static HardwareSerial &LINK = Serial2;

struct cyd_link {
    uint32_t last_rx_ms;      /* when a STATUS last arrived */
    uint32_t len;             /* bytes currently in `line`  */
    bool     overflow;        /* current line already too long */
    char     line[CYD_LINE_MAX];
};

static cyd_link g_link;

cyd_link_t *cyd_link_uart_open(int baud)
{
    memset(&g_link, 0, sizeof g_link);

    /* Pins given explicitly: Serial2 defaults to GPIO16/17, the RGB LED. */
    /* BEFORE begin(), which is the only time it can be set.
     *
     * The default is 256 bytes and that is too small for this protocol. An
     * OTA chunk line is 689 bytes ("OTA " + 684 base64 + newline), and while
     * an update is running every pass of the loop also does a flash write and
     * a screen repaint -- so the driver's ring has to hold a whole line while
     * the application is busy elsewhere. At 256 it does not: measured on
     * hardware 2026-09-05, the panel received 414 of the first 512-byte chunk
     * and the transfer was refused on the spot by the byte-count check.
     *
     * 4096 is ~355ms of slack at 115200, far longer than any flash erase, and
     * costs 4KB of the 320KB the panel barely uses (7.5%). */
    LINK.setRxBufferSize(4096);

    LINK.begin(baud > 0 ? baud : CYD_BAUD_DEFAULT, SERIAL_8N1,
               CYD_LINK_RX_PIN, CYD_LINK_TX_PIN);

    /* Started at "never heard from", so age_ms is large immediately and the
     * UI shows MINER DOWN until a real STATUS lands. Starting at 0 would
     * claim a fresh reading before anything had been received -- the panel
     * would look healthy for the first few seconds of a dead link, which is
     * the wrong way round for something whose job is to tell you the miner
     * stopped. */
    g_link.last_rx_ms = 0;
    return &g_link;
}

/* One complete line. Returns true if `out` was updated by a STATUS. */
static bool handle_line(cyd_link_t *l, char *line, cyd_status_t *out)
{
    /* OTA FIRST. During an update the chunks are the only traffic that
     * matters and by far the highest rate on the link, and cyd_ota_handle_line
     * answers each one itself. It returns true only for OTA messages, so
     * nothing else is affected when no update is running.
     *
     * Returning false, not true: an OTA line never updates `out`, and
     * claiming it did would make the caller redraw a status that has not
     * changed. */
    if (cyd_ota_handle_line(line, LINK))
        return false;

    if (strncmp(line, CYD_MSG_STATUS, strlen(CYD_MSG_STATUS)) == 0) {
        if (cyd_status_parse(line + strlen(CYD_MSG_STATUS), out)) {
            l->last_rx_ms = millis();
            out->age_ms   = 0;
            return true;
        }
        return false;
    }

    if (strncmp(line, CYD_MSG_PING, strlen(CYD_MSG_PING)) == 0) {
        LINK.print(CYD_MSG_PONG);
        LINK.print('\n');
        return false;
    }

    /* HELLO, and anything else, ignored. An unknown line must never be an
     * error: it is how the protocol stays extensible, and how a stray debug
     * print from either end fails to break the link. */
    return false;
}

bool cyd_link_poll(cyd_link_t *link, cyd_status_t *out)
{
    if (!link || !out)
        return false;

    bool updated = false;

    /* Bounded per call. The UI loop has to keep running: draining an
     * unbounded backlog here would stall redraws and touch handling for as
     * long as the miner cared to talk. */
    /* Raised from 512 with the RX buffer, and for the same reason: a single
     * OTA line is 689 bytes, so a 512-byte budget could not consume one in a
     * pass however much the driver had buffered. It only ever reads what is
     * actually available -- in normal running that is one ~700-byte status a
     * second, so this changes nothing there. */
    int budget = 2048;
    while (LINK.available() > 0 && budget-- > 0) {
        int c = LINK.read();
        if (c < 0)
            break;

        if (c == '\n' || c == '\r') {
            if (link->len > 0 && !link->overflow) {
                link->line[link->len] = '\0';
                if (handle_line(link, link->line, out))
                    updated = true;
            }
            link->len = 0;
            link->overflow = false;
            continue;
        }

        if (link->len + 1 < sizeof link->line) {
            link->line[link->len++] = (char)c;
        } else {
            /* Too long. DROP THE WHOLE LINE rather than truncate and parse:
             * a truncated JSON object can still parse into something
             * plausible, and half a status is worse than none. The flag
             * clears at the next newline, so the link resynchronises. */
            link->overflow = true;
            link->len = 0;
        }
    }

    /* Age is reported even when nothing arrived -- it is what drives the
     * MINER DOWN state, and the caller cannot compute it without knowing
     * when the last line landed. */
    out->age_ms = link->last_rx_ms ? (millis() - link->last_rx_ms)
                                   : 0xFFFFFFFFu;
    return updated;
}

/* ---- commands ---------------------------------------------------------
 *
 * These return whether the line was SENT, not whether it was carried out.
 * The link is one-way for commands by design: the miner applies them to
 * /run/odod flag files and /boot/am01-miner.conf, and the result shows up in
 * the next STATUS. Waiting for an ack here would mean blocking the UI on a
 * link that may be down, and the honest confirmation is the status changing.
 */

static bool send_cmd(const char *cmd)
{
    LINK.print(CYD_CMD_PREFIX);
    LINK.print(cmd);
    LINK.print('\n');
    return true;
}

bool cyd_link_fan_boost(cyd_link_t *link, bool on)
{
    (void)link;
    char b[48];
    snprintf(b, sizeof b, "%s %d", CYD_CMD_FAN_BOOST, on ? 1 : 0);
    return send_cmd(b);
}

bool cyd_link_reset_stats(cyd_link_t *link)
{
    (void)link;
    return send_cmd(CYD_CMD_RESET_STAT);
}

bool cyd_link_reboot(cyd_link_t *link)
{
    (void)link;
    return send_cmd(CYD_CMD_REBOOT);
}

bool cyd_link_restart(cyd_link_t *link)
{
    (void)link;
    return send_cmd(CYD_CMD_RESTART);
}

bool cyd_link_set_wifi(cyd_link_t *link, const char *ssid, const char *psk)
{
    (void)link;
    if (!ssid || !psk || !*ssid)
        return false;
    size_t n = strlen(psk);
    if (n < 8 || n > 63)          /* the daemon would reject it anyway */
        return false;
    char b[CYD_LINE_MAX];
    /* PSK LAST and unquoted: the parser takes the remainder of the line
     * whole, which is what lets a passphrase contain spaces. */
    snprintf(b, sizeof b, "%s %s %s", CYD_CMD_SET_WIFI, ssid, psk);
    return send_cmd(b);
}

bool cyd_link_set_pool(cyd_link_t *link, const char *host, int port,
                       const char *worker, const char *pass)
{
    (void)link;
    if (!host || !worker || !pass)
        return false;

    char b[CYD_LINE_MAX];
    /* snprintf, and the result checked: a pool line that silently lost its
     * password would be written to /boot/am01-miner.conf and survive a
     * reflash, which is a long way to carry a truncation bug. */
    int n = snprintf(b, sizeof b, "%s %s %d %s %s",
                     CYD_CMD_SET_POOL, host, port, worker, pass);
    if (n < 0 || (size_t)n >= sizeof b)
        return false;
    return send_cmd(b);
}
