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

#include <Arduino.h>
#include <stdlib.h>      /* millis(), and the Arduino entry points */

#include "cyd_link.h"
#include "cyd_ota.h"
#include "cyd_ui.h"

static cyd_link_t  *g_link;
static cyd_ui_t     g_ui;
static cyd_status_t g_status;

void setup(void)
{
    cyd_ui_init(&g_ui);
    cyd_ui_backend_init();     /* TFT, rotation, backlight */

    /* The link: FPGA-hosted UART on JP5 15/16. 115200 because the payload is
     * one status line a second, and the entire point of leaving SPI behind
     * was to stop spending signal-integrity margin we do not need.
     *
     * The only transport. A WiFi one used to sit behind a CYD_USE_UART ifdef
     * here -- and was the default -- which contradicted the requirement this
     * panel exists to meet. Removed 2026-09-01, unimplemented. */
    g_link = cyd_link_uart_open(CYD_BAUD_DEFAULT);
}

void loop(void)
{
    /* Redraw on CHANGE, not on a timer. The status moves once a second and
     * the panel sits on top of a miner that is already drawing ~12A on the
     * core rail; a free-running repaint loop spends power to display nothing
     * new. odo-ui takes the same approach. */
    /* AN UPDATE OWNS THE PANEL. While one is running, the normal screen is
     * both wrong (the status stops arriving) and dangerous to show: a frozen
     * hashrate for a minute is how someone decides the panel has hung and
     * pulls the power, mid flash-write. Touch is ignored for the same reason.
     *
     * The poll still runs -- that is what feeds the OTA chunks in. */
    if (cyd_ota_active()) {
        cyd_link_poll(g_link, &g_status);
        cyd_ui_draw_ota(cyd_ota_percent(), NULL);
        return;
    }
    {
        /* Drawn ONCE -- take_error clears it -- and then the next status
         * redraws the normal screen over the top. A failed update must not be
         * silent, but it must not become the permanent display either: the
         * panel is still running its old firmware and still has a miner to
         * report on. */
        const char *ota_err = cyd_ota_take_error();
        if (ota_err[0] != '\0')
            cyd_ui_draw_ota(0, ota_err);
    }

    if (cyd_link_poll(g_link, &g_status)) {
        /* Prefill the pool editor from what the miner reports, so a pool
         * change is an edit rather than typing a host from memory. It
         * declines to touch anything while POOL or KEYBOARD is open, so a
         * once-a-second status cannot overwrite half-typed input. */
        cyd_ui_pool_sync(&g_ui, &g_status);
        g_ui.link_down = false;
        cyd_ui_draw(&g_ui, &g_status);
    } else if (g_status.age_ms > CYD_LINK_STALE_MS && !g_ui.link_down) {
        /* Say so rather than leaving the last good numbers on screen. A stale
         * reading presented as live is worse than an honest "no data" -- it
         * is how someone concludes the miner is fine while it is down. */
        g_ui.link_down = true;
        cyd_ui_draw(&g_ui, &g_status);
    }

    /* EDGE-TRIGGERED. Without it, one held press walks
     * GLANCE -> ACTIONS -> CONFIRM -> YES and reboots the miner in
     * milliseconds -- CYD_CONFIRM_YES is the same rectangle as ACTIONS'
     * REBOOT button, and touch is polled every loop.
     *
     * The state machine lives in cyd_ui.c so it can be TESTED. It was inline
     * here and wrong twice: once with no edge detection, once with a debounce
     * that re-armed its own timer every iteration so the release never fired
     * and the panel died after a single touch. Neither was visible to the
     * test suite, because this file cannot be built on a PC. */
    static cyd_touch_edge_t edge;
    static bool edge_ready = false;
    if (!edge_ready) { cyd_touch_edge_init(&edge); edge_ready = true; }

    int tx, ty;
    bool down = cyd_ui_touch_read(&tx, &ty);

    switch (cyd_touch_edge_update(&edge, down, millis(), 40)) {
    case CYD_TOUCH_RELEASE:
        /* Tell the model the finger lifted -- the second of the two guards on
         * the reboot path, and the one sim/test_cyd_ui.c can prove. */
        cyd_ui_touch_release(&g_ui);
        break;

    case CYD_TOUCH_PRESS: {
        g_ui.last_touch_ms = millis();
        cyd_action_t act = cyd_ui_touch(&g_ui, tx, ty);

        /* The UI decides WHAT was asked for; this decides whether it happens.
         * Keeping the side effects out of cyd_ui_touch() is what lets the
         * screen logic be exercised without a link, and stops the UI quietly
         * acquiring the ability to reboot the miner. */
        switch (act) {
        case CYD_ACTION_RESET_STATS: cyd_link_reset_stats(g_link); break;
        case CYD_ACTION_REBOOT:      cyd_link_reboot(g_link);      break;
        case CYD_ACTION_FAN_BOOST:
            cyd_link_fan_boost(g_link, g_ui.fan_boost);
            break;
        case CYD_ACTION_SET_POOL:
            /* atoi is safe here: the keyboard refuses non-digits in the
             * port field, and SAVE refuses to fire on an empty one. */
            cyd_link_set_pool(g_link, g_ui.pool_host,
                              atoi(g_ui.pool_port),
                              g_ui.pool_worker, g_ui.pool_pass);
            break;
        case CYD_ACTION_RESTART:
            cyd_link_restart(g_link);
            break;
        case CYD_ACTION_SET_WIFI:
            cyd_link_set_wifi(g_link, g_ui.wifi_ssid, g_ui.wifi_psk);
            break;
        case CYD_ACTION_NONE:        break;
        }

        cyd_ui_draw(&g_ui, &g_status);
        break;
    }

    case CYD_TOUCH_NONE:
    default:
        break;
    }

    /* ---- backlight ---------------------------------------------------
     * Applied HERE rather than inside the UI: dimming is a decision about how
     * long the panel has been untouched, and the screen model has no clock.
     * Without this the SETTINGS controls change a number that does nothing. */
    {
        static uint8_t applied = 255;
        uint8_t want = 100;
        if (g_ui.dim_timeout_s > 0 && g_ui.last_touch_ms) {
            uint32_t idle = millis() - g_ui.last_touch_ms;
            if (idle > g_ui.dim_timeout_s * 1000u)
                want = g_ui.dim_level;
        }
        if (want != applied) {
            cyd_ui_set_backlight(want);
            applied = want;
        }
    }
}
