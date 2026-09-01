/*
 * cyd_ui.h -- screen model for the CYD front panel.
 *
 * SCAFFOLDING. Not compiled into anything yet.
 *
 * PORTED FROM odo-miner-cyclonev/sw/odo-ui, NOT designed here. That UI already
 * targets 320x240 RGB565 with an XPT2046 touch controller -- which is exactly
 * what a CYD is -- and already consumes the same status object this panel
 * receives. Keeping its layout means the panel, the web dashboard and the
 * miner cannot drift into showing three different vocabularies for the same
 * numbers.
 *
 * `generated_screens/` and `mock_dashboard.png` in that tree are the visual
 * reference. Do not invent a new layout: the point of choosing this panel is
 * that the miner already has one.
 */

#ifndef CYD_UI_H
#define CYD_UI_H

#include "cyd_link.h"

/* 2.8" CYD panel, landscape. Same geometry odo-ui assumes. */
#define CYD_W 320
#define CYD_H 240

typedef enum {
    CYD_SCREEN_GLANCE = 0,  /* hashrate, pool, ACC/REJ, uptime            */
    CYD_SCREEN_DETAIL,      /* + epoch, job, fan, best diff, backend      */
    CYD_SCREEN_SETTINGS,    /* dim level, dim timeout                     */
    CYD_SCREEN_ACTIONS,     /* RESET STATS, REBOOT                        */
    CYD_SCREEN_CONFIRM,     /* guards anything destructive                */
    CYD_SCREEN_COUNT
} cyd_screen_t;

/* What a CONFIRM screen is confirming. A panel that can reboot the miner on
 * one stray touch is a panel that eventually will -- odo-ui guards these and
 * so does this. */
typedef enum {
    CYD_ACTION_NONE = 0,
    CYD_ACTION_RESET_STATS,
    CYD_ACTION_REBOOT
} cyd_action_t;

typedef struct {
    cyd_screen_t screen;
    cyd_action_t pending;       /* what CONFIRM would carry out           */

    /* Backlight. Dimming is not decoration: this sits next to a miner that
     * runs 24/7, and a panel at full brightness all night is a nuisance.
     * Values carried in the status object so the web UI and the panel agree. */
    uint8_t  dim_level;         /* 0-100, brightness when dimmed          */
    uint32_t dim_timeout_s;     /* 0 = never dim                          */
    uint32_t last_touch_ms;

    bool     link_down;         /* drives the MINER DOWN state            */
} cyd_ui_t;

void cyd_ui_init(cyd_ui_t *ui);

/* Draw. Called on a fresh status or a touch, not free-running: a full repaint
 * every frame is wasted power on a panel that changes once a second, and this
 * is sitting on top of a miner where the power budget is not free. */
void cyd_ui_draw(cyd_ui_t *ui, const cyd_status_t *st);

/* Touch. Returns the action to carry out, or CYD_ACTION_NONE. Deliberately
 * does NOT call the link itself -- the caller owns that, so this stays
 * testable off-hardware and the UI cannot quietly acquire side effects. */
cyd_action_t cyd_ui_touch(cyd_ui_t *ui, int x, int y);

/* Formatting shared with the drawing code, and the reason it is declared here
 * rather than left inline: these are the places a panel most easily lies.
 *
 *   hashrate  -> "68.4 MH/s"
 *   temp/fan  -> "--" when the value is -1, NEVER "-1 C". The miner reports
 *                -1 for "could not read", and rendering that literally would
 *                look like a board fault rather than a reporting gap.
 *   epoch     -> time remaining, since the absolute unix seconds mean nothing
 *                at a glance and the thing that matters is how long until the
 *                bitstream must be rebuilt.
 */
void cyd_fmt_hashrate(double h_per_s, char *out, int n);
void cyd_fmt_temp(int temp_c, char *out, int n);
void cyd_fmt_fan(int rpm, int duty_pct, char *out, int n);
/* Takes `now` EXPLICITLY rather than calling time(). The ESP32's clock is not
 * necessarily set -- there is no RTC on a CYD and NTP may never have run --
 * so the trustworthy clock is the miner's, arriving in the status object. A
 * formatter that reached for a global clock would render a confident,
 * completely wrong countdown on a panel that had just booted, and could not
 * be tested against a fixed instant. */
void cyd_fmt_epoch_left_at(uint32_t epoch_next, uint32_t now, char *out, int n);

#endif /* CYD_UI_H */
