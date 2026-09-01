/*
 * main.cpp -- CYD front panel entry point.
 *
 * SCAFFOLDING. Does not build: no board support is pulled in yet, and the
 * cyd_link transports are unimplemented. Committed so the shape is fixed
 * before the details, and so the host and firmware halves are written against
 * one protocol rather than two.
 *
 * Nothing here touches the existing ILI9341 path, which is still the live
 * solution.
 *
 * BUILD (once the transports exist): PlatformIO, board esp32dev, with
 * TFT_eSPI configured for the ESP32-2432S028R pin map. That configuration is
 * board-specific and notoriously easy to get wrong -- the display and the
 * touch controller are on SEPARATE SPI buses on this hardware, which is the
 * usual reason a CYD sketch shows a working display and a dead touchscreen.
 */

#include "cyd_link.h"
#include "cyd_ui.h"

/* Development transport vs the real one.
 *
 * WiFi first, on purpose: it lets the whole UI be built and looked at while
 * hdl/uart_bridge.v is still being written, instead of the firmware being
 * blocked behind a 1h35m bitstream turnaround. The switch to the UART then
 * replaces one function call, because nothing above this line knows which
 * transport it is talking to. */
#ifndef CYD_USE_UART
#define CYD_USE_UART 0
#endif

static cyd_link_t  *g_link;
static cyd_ui_t     g_ui;
static cyd_status_t g_status;

void setup(void)
{
    cyd_ui_init(&g_ui);

#if CYD_USE_UART
    /* The real link: FPGA-hosted UART on JP5 pins 15/16. 115200 because the
     * payload is one status line a second and the entire point of leaving SPI
     * behind was to stop spending signal-integrity margin we do not need. */
    g_link = cyd_link_uart_open(CYD_BAUD_DEFAULT);
#else
    /* Development only. Polls odo-webd, which already serves the same status
     * object on port 8080. */
    g_link = cyd_link_wifi_open("192.168.1.26", 8080);
#endif
}

void loop(void)
{
    /* Redraw on CHANGE, not on a timer. The status moves once a second and
     * the panel sits on top of a miner that is already drawing ~12A on the
     * core rail; a free-running repaint loop spends power to display nothing
     * new. odo-ui takes the same approach. */
    if (cyd_link_poll(g_link, &g_status)) {
        g_ui.link_down = false;
        cyd_ui_draw(&g_ui, &g_status);
    } else if (g_status.age_ms > CYD_LINK_STALE_MS && !g_ui.link_down) {
        /* Say so rather than leaving the last good numbers on screen. A stale
         * reading presented as live is worse than an honest "no data" -- it
         * is how someone concludes the miner is fine while it is down. */
        g_ui.link_down = true;
        cyd_ui_draw(&g_ui, &g_status);
    }

    int tx, ty;
    if (/* touch_read(&tx, &ty) */ false) {
        cyd_action_t act = cyd_ui_touch(&g_ui, tx, ty);

        /* The UI decides WHAT was asked for; this decides whether it happens.
         * Keeping the side effects out of cyd_ui_touch() is what lets the
         * screen logic be exercised without a link, and stops the UI quietly
         * acquiring the ability to reboot the miner. */
        switch (act) {
        case CYD_ACTION_RESET_STATS: cyd_link_reset_stats(g_link); break;
        case CYD_ACTION_REBOOT:      cyd_link_reboot(g_link);      break;
        case CYD_ACTION_NONE:        break;
        }

        cyd_ui_draw(&g_ui, &g_status);
    }
}
