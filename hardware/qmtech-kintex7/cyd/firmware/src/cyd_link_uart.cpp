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
 * IT USES Serial. UART0. THE SAME PORT AS THE USB CONSOLE.
 * ---------------------------------------------------------------------------
 * Not a choice: the CYD's P5 connector carries VIN/TX/RX/GND, and its TX/RX
 * are GPIO1/GPIO3 -- UART0 -- which is also what the onboard CH340 drives.
 * There is no second UART broken out. P3 and CN1 carry GPIO21/22/27/35 only.
 *
 * Two consequences that are easy to get bitten by:
 *
 *   1. USB AND P5 MUST NEVER BOTH BE CONNECTED. Two drivers on one pair.
 *   2. NOTHING MAY Serial.print() FOR DEBUGGING once this is running -- it
 *      goes down the link and the daemon has to skip it. Unknown lines are
 *      ignored by both ends precisely so a stray print is survivable, but it
 *      is still noise on the wire, so this file emits nothing uninvited.
 *
 * The protocol is line-oriented text (see ../host/cyd_proto.h), which is what
 * makes that tolerable at all -- a binary framing would desynchronise on the
 * first stray byte.
 */

#include <Arduino.h>

#include "cyd_link.h"
#include "cyd_status_parse.h"

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

    /* SERIAL_8N1 on the default UART0 pins, which are the ones P5 exposes. */
    Serial.begin(baud > 0 ? baud : CYD_BAUD_DEFAULT);

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
    if (strncmp(line, CYD_MSG_STATUS, strlen(CYD_MSG_STATUS)) == 0) {
        if (cyd_status_parse(line + strlen(CYD_MSG_STATUS), out)) {
            l->last_rx_ms = millis();
            out->age_ms   = 0;
            return true;
        }
        return false;
    }

    if (strncmp(line, CYD_MSG_PING, strlen(CYD_MSG_PING)) == 0) {
        Serial.print(CYD_MSG_PONG);
        Serial.print('\n');
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
    int budget = 512;
    while (Serial.available() > 0 && budget-- > 0) {
        int c = Serial.read();
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
    Serial.print(CYD_CMD_PREFIX);
    Serial.print(cmd);
    Serial.print('\n');
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
