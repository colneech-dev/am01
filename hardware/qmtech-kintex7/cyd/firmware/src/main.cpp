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
#include <Preferences.h>
#include <stdlib.h>      /* millis(), and the Arduino entry points */

#include "cyd_link.h"
#include "cyd_ota.h"
#include "cyd_ui.h"
#include "cyd_ui_layout.h"
#include <string.h>

/*
 * The dim settings survive a reboot, in NVS.
 *
 * They are the only settings the panel owns outright -- everything else it
 * shows belongs to the miner and arrives in a STATUS. Losing them on every
 * power cut made the SETTINGS screen look broken: you set the panel to dim
 * after 30s, and it forgot the moment anything restarted it, including an
 * over-the-wire firmware update.
 *
 * Kept here rather than in cyd_ui.c on purpose: that file is pure C so the
 * screen model can run on a PC (sim/test_cyd_ui.c), and it must not learn
 * about NVS to do it.
 */
static Preferences g_prefs;

static cyd_link_t  *g_link;
static cyd_ui_t     g_ui;
static cyd_status_t g_status;

void setup(void)
{
    /* USB console. The link lives on CN1 now, so UART0 is free and a print
     * here cannot corrupt the protocol -- see cyd_link_uart.cpp. */
    Serial.begin(115200);
    delay(200);
    Serial.println();
    Serial.println(F("=== CYD panel boot ==="));

    cyd_ui_init(&g_ui);

    /* AFTER cyd_ui_init, which sets the defaults this overrides -- and before
     * backend_init, so the backlight comes up at the remembered level rather
     * than flashing full brightness first. */
    g_prefs.begin("cyd", false);
    g_ui.dim_level     = g_prefs.getUChar("dim_lvl", g_ui.dim_level);
    g_ui.dim_timeout_s = g_prefs.getULong("dim_tmo", g_ui.dim_timeout_s);

    cyd_ui_backend_init();     /* TFT, rotation, backlight */

    {
        extern uint32_t g_canvas_diag_heap, g_canvas_diag_maxblk;
        extern bool cyd_ui_canvas_ok(void);
        Serial.printf("canvas=%d  free heap=%lu  largest block=%lu\n",
                      cyd_ui_canvas_ok() ? 1 : 0,
                      (unsigned long)g_canvas_diag_heap,
                      (unsigned long)g_canvas_diag_maxblk);
        Serial.printf("a full 320x240x16bpp canvas needs %d contiguous bytes\n",
                      320 * 240 * 2);
    }

    /* The link: FPGA-hosted UART on JP5 15/16. 115200 because the payload is
     * one status line a second, and the entire point of leaving SPI behind
     * was to stop spending signal-integrity margin we do not need.
     *
     * The only transport. A WiFi one used to sit behind a CYD_USE_UART ifdef
     * here -- and was the default -- which contradicted the requirement this
     * panel exists to meet. Removed 2026-09-01, unimplemented. */
    g_link = cyd_link_uart_open(CYD_BAUD_DEFAULT);

    /* Scan results land straight in the UI state. */
    cyd_link_set_scan_sink(&g_ui);

    /* One diagnostic line, once, up the link -- the miner logs it. The
     * USB console is the obvious place for this, but the panel lives in a
     * case with only the CN1 pair attached, so the link is the only way
     * to find out what the firmware actually did on real hardware. */
    {
        extern uint32_t g_canvas_diag_heap, g_canvas_diag_maxblk;
        extern bool cyd_ui_canvas_ok(void);
        char d[96];
        snprintf(d, sizeof d, "DIAG canvas=%d heap=%lu maxblk=%lu\n",
                 cyd_ui_canvas_ok() ? 1 : 0,
                 (unsigned long)g_canvas_diag_heap,
                 (unsigned long)g_canvas_diag_maxblk);
        cyd_link_send_raw(g_link, d);
    }
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

    /* The BUSY screen counts seconds and the model has no clock, so it is
     * given one -- and redrawn while it is up, since nothing else will. */
    if (g_ui.screen == CYD_SCREEN_BUSY) {
        static uint32_t last_tick;
        g_ui.busy_now_ms = millis();
        if (g_ui.busy_now_ms - last_tick > 500) {
            last_tick = g_ui.busy_now_ms;
            cyd_ui_draw(&g_ui, &g_status);
        }
    }

    if (cyd_link_poll(g_link, &g_status)) {
        /* Prefill the pool editor from what the miner reports, so a pool
         * change is an edit rather than typing a host from memory. It
         * declines to touch anything while POOL or KEYBOARD is open, so a
         * once-a-second status cannot overwrite half-typed input. */
        cyd_ui_pool_sync(&g_ui, &g_status);

        /* OUT OF THE BUSY SCREEN, ON EVIDENCE.
         *
         * UPTIME GOING BACKWARDS is the proof: only a miner that actually
         * restarted reports a smaller uptime than the one that was asked to.
         *
         * The first attempt waited for the link to be declared DOWN and then
         * return. That was wrong: CYD_LINK_STALE_MS is 5s and a restart takes
         * 3-5s, so the link frequently never went stale, the transition never
         * happened, and the screen waited for ever.
         *
         * Down-then-up is kept as a second route, for a miner that takes long
         * enough that the link really does go stale first. */
        static bool busy_saw_down;
        if (g_ui.screen == CYD_SCREEN_BUSY) {
            bool restarted = (g_status.uptime < g_ui.busy_uptime0);
            if (g_ui.link_down)
                busy_saw_down = true;

            if (restarted || (busy_saw_down && !g_ui.link_down)) {
                busy_saw_down      = false;
                g_ui.busy_what     = NULL;
                g_ui.busy_since_ms = 0;
                g_ui.busy_uptime0  = 0;
                g_ui.screen        = CYD_SCREEN_GLANCE;
            }
        } else {
            busy_saw_down = false;
        }

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

        /* TAP THE FIELD TO PLACE THE CURSOR.
         *
         * Handled here rather than inside cyd_ui_touch() because working out
         * WHICH character was tapped needs the font, and the screen model
         * deliberately has none -- see cyd_ui_kb_index_at().
         *
         * The SHOW/HIDE toggle sits at the right-hand end of the same row, so
         * it is excluded: it is a control that happens to live inside the
         * field, and it must keep working. */
        bool placed = false;
        if (g_ui.screen == CYD_SCREEN_KEYBOARD &&
            cyd_rect_hit(CYD_KB_FIELD, tx, ty) &&
            !(cyd_ui_field_is_secret(g_ui.edit_field) &&
              cyd_rect_hit(CYD_KB_EYE, tx, ty))) {
            size_t cap = 0;
            char *buf = cyd_ui_field(&g_ui, g_ui.edit_field, &cap);
            g_ui.kb_cursor = cyd_ui_kb_index_at(&g_ui, tx);
            cyd_ui_kb_follow(&g_ui, buf ? strlen(buf) : 0);
            placed = true;
        }

        cyd_action_t act = placed ? CYD_ACTION_NONE
                                  : cyd_ui_touch(&g_ui, tx, ty);

        /* The UI decides WHAT was asked for; this decides whether it happens.
         * Keeping the side effects out of cyd_ui_touch() is what lets the
         * screen logic be exercised without a link, and stops the UI quietly
         * acquiring the ability to reboot the miner. */
        switch (act) {
        case CYD_ACTION_RESET_STATS: cyd_link_reset_stats(g_link); break;
        case CYD_ACTION_REBOOT:
            cyd_link_reboot(g_link);
            /* The whole board goes down: miner, CM4, network. The panel is
             * powered separately and stays up, which is the point -- it is
             * the only thing left that can say what is happening. */
            g_ui.busy_what     = "REBOOTING";
            g_ui.busy_since_ms = millis();
            g_ui.busy_uptime0  = g_status.uptime;
            g_ui.screen        = CYD_SCREEN_BUSY;
            break;
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
            /* Only the mining daemon: seconds, not a boot. Same screen, so
             * there is one place to look whatever was asked for. */
            g_ui.busy_what     = "RESTARTING MINER";
            g_ui.busy_since_ms = millis();
            g_ui.busy_uptime0  = g_status.uptime;
            g_ui.screen        = CYD_SCREEN_BUSY;
            break;
        case CYD_ACTION_SET_WIFI:
            cyd_link_set_wifi(g_link, g_ui.wifi_ssid, g_ui.wifi_psk);
            break;
        case CYD_ACTION_WIFI_SCAN:
            cyd_link_wifi_scan(g_link);
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

    /* ---- remember the dim settings -----------------------------------
     * DEBOUNCED. Holding + on the brightness control walks the value in steps
     * and each one would otherwise be a flash write; NVS has a finite erase
     * budget and there is no reason to spend it on intermediate values nobody
     * chose. Written once the setting has been still for 3 seconds. */
    {
        static uint8_t  saved_level = 0xFF;
        static uint32_t saved_tmo   = 0xFFFFFFFFu;
        static uint32_t dirty_since;

        bool changed = (g_ui.dim_level != saved_level ||
                        g_ui.dim_timeout_s != saved_tmo);

        if (changed && dirty_since == 0) {
            dirty_since = millis();
            if (dirty_since == 0) dirty_since = 1;   /* 0 means "clean" */
        } else if (!changed) {
            dirty_since = 0;
        }

        if (dirty_since && (millis() - dirty_since) > 3000) {
            if (saved_level != 0xFF || saved_tmo != 0xFFFFFFFFu) {
                /* Not on the first pass: those sentinels are "unknown", not a
                 * change the user made, and writing then would put the
                 * defaults into NVS before anyone had touched anything. */
                g_prefs.putUChar("dim_lvl", g_ui.dim_level);
                g_prefs.putULong("dim_tmo", g_ui.dim_timeout_s);
            }
            saved_level = g_ui.dim_level;
            saved_tmo   = g_ui.dim_timeout_s;
            dirty_since = 0;
        }
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
