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

#include <Arduino.h>      /* millis(), and the Arduino entry points */

#include "cyd_link.h"
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

    /* EDGE-TRIGGERED, and this is not a refinement -- without it the panel
     * reboots the miner on a single held tap.
     *
     * cyd_ui_touch_read() returns true for EVERY loop iteration a finger is
     * down, tens of times per press. CYD_CONFIRM_YES is the same rectangle as
     * ACTIONS' REBOOT button (both are CYD_BTN_RIGHT), so one continuous
     * press on the right-hand button walks GLANCE -> ACTIONS -> CONFIRM ->
     * YES and reboots, in a few milliseconds, with the confirm screen never
     * visible.
     *
     * sim/test_cyd_ui.c proved no SINGLE CALL can trigger an action, and that
     * remains true -- the model was never wrong. The bug was that one physical
     * touch is many calls. The test now covers held presses too.
     *
     * The release must also be debounced: a resistive panel chatters, and a
     * bounce reads as release-then-press, which is another dispatch. */
    static bool     was_down = false;
    static uint32_t up_since = 0;
    const uint32_t  DEBOUNCE_MS = 40;

    int tx, ty;
    bool down = cyd_ui_touch_read(&tx, &ty);

    if (!down) {
        if (was_down) up_since = millis();
        /* Only treat it as released once it has been up for the debounce
         * window; until then keep was_down set so a bounce cannot re-arm. */
        if (up_since && millis() - up_since >= DEBOUNCE_MS) {
            was_down = false;
            /* Tell the model the finger lifted. Until this, cyd_ui_touch()
             * refuses to return an action after a screen change -- the second
             * of the two guards on the reboot path, and the one that is
             * actually testable (sim/test_cyd_ui.c). */
            cyd_ui_touch_release(&g_ui);
        }
    } else if (!was_down) {
        was_down = true;
        up_since = 0;

        g_ui.last_touch_ms = millis();
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
