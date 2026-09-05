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

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include "cyd_link.h"

/* 2.8" CYD panel, landscape. Same geometry odo-ui assumes. */
#define CYD_W 320
#define CYD_H 240

typedef enum {
    CYD_SCREEN_GLANCE = 0,  /* hashrate, pool, ACC/REJ, uptime            */
    CYD_SCREEN_DETAIL,      /* + epoch, job, fan, best diff, backend      */
    CYD_SCREEN_SETTINGS,    /* dim level, dim timeout                     */
    CYD_SCREEN_ACTIONS,     /* RESET STATS, REBOOT, FAN BOOST             */
    CYD_SCREEN_CONFIRM,     /* guards anything destructive                */
    CYD_SCREEN_POOL,        /* host / port / worker / pass, tap to edit   */
    CYD_SCREEN_KEYBOARD,    /* on-screen entry for one POOL field         */
    CYD_SCREEN_MENU,        /* the hamburger's modal action sheet         */
    CYD_SCREEN_WIFI,        /* SSID + PSK, shares the keyboard            */
    CYD_SCREEN_COUNT
} cyd_screen_t;

/* What a CONFIRM screen is confirming. A panel that can reboot the miner on
 * one stray touch is a panel that eventually will -- odo-ui guards these and
 * so does this. */
typedef enum {
    CYD_ACTION_NONE = 0,
    CYD_ACTION_RESET_STATS,
    CYD_ACTION_REBOOT,
    /* NOT confirmed, deliberately: reversible and harmless. Only the two
     * above can lose work, and only those go through CONFIRM. */
    CYD_ACTION_FAN_BOOST,
    /* Confirmed, because it rewrites where the miner earns to. The new values
     * are in ui->pool_* when this is returned. */
    CYD_ACTION_SET_POOL,
    /* Confirmed: it drops the miner for a few seconds. */
    CYD_ACTION_RESTART,
    /* Confirmed: getting this wrong takes a headless board off the network. */
    CYD_ACTION_SET_WIFI
} cyd_action_t;

/* Field sizes. Worker is the roomiest because it is <wallet>.<name> and the
 * wallet alone is ~34 base58 characters. */
#define CYD_POOL_HOST_MAX   64
#define CYD_POOL_PORT_MAX    8
#define CYD_POOL_WORKER_MAX 96
#define CYD_POOL_PASS_MAX   32
/* WPA2 allows a 63-character passphrase; 80 leaves room for the nul and
 * for a too-long entry to be REJECTED rather than silently truncated. */
#define CYD_WIFI_SSID_MAX   64
#define CYD_WIFI_PSK_MAX    80

/* Which POOL row the keyboard is editing. Order matches CYD_POOL_ROW(i). */
typedef enum {
    CYD_FIELD_HOST = 0,
    CYD_FIELD_PORT,
    CYD_FIELD_WORKER,
    CYD_FIELD_PASS,
    CYD_FIELD_SSID,
    CYD_FIELD_PSK,
    CYD_FIELD_COUNT
} cyd_field_t;

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

    /* Set whenever the screen changes; cleared by cyd_ui_touch_release().
     * While set, no action can be returned.
     *
     * DEFENCE IN DEPTH on the only path that can reboot the miner. The caller
     * dispatches on the rising edge, which is the primary guard -- but that
     * lives in main.cpp and cannot be tested off hardware, and it is exactly
     * the guard that was missing when this shipped. This one is in the model,
     * so sim/test_cyd_ui.c can prove it. */
    bool     needs_release;

    /* Fan boost, mirrored locally so the button can show its state. The miner
     * owns the real value; this is what the user last asked for. */
    bool     fan_boost;

    /* POOL editor. Held as a working copy so an abandoned edit changes
     * nothing -- the miner is only told on SAVE, and set_pool rewrites
     * /boot/am01-miner.conf, which survives a reflash. */
    char        pool_host[CYD_POOL_HOST_MAX];
    char        pool_port[CYD_POOL_PORT_MAX];
    char        pool_worker[CYD_POOL_WORKER_MAX];
    char        pool_pass[CYD_POOL_PASS_MAX];
    char        wifi_ssid[CYD_WIFI_SSID_MAX];
    char        wifi_psk[CYD_WIFI_PSK_MAX];
    cyd_field_t edit_field;     /* which row the keyboard is editing      */
    bool        kb_shift;       /* uppercase for the next character       */
    /* The field as it was when the keyboard opened, so CANCEL means
     * "discard this edit" rather than "clear the field". Sized to
     * the largest field. */
    char        kb_backup[CYD_POOL_WORKER_MAX];
} cyd_ui_t;

/* The buffer and capacity for one field, so the keyboard and the drawing code
 * cannot disagree about which is which. Returns NULL for a bad index. */
char *cyd_ui_field(cyd_ui_t *ui, cyd_field_t f, size_t *cap);

/* Keep host/port in step with what the miner reports, WITHOUT
 * clobbering an edit in progress. Safe to call on every status
 * update. */
void cyd_ui_pool_sync(cyd_ui_t *ui, const cyd_status_t *st);

/* The character a keyboard cell carries, honouring shift. col/row are grid
 * coordinates; returns 0 when out of range. */
char cyd_ui_kb_char(int col, int row, bool shift);

void cyd_ui_init(cyd_ui_t *ui);

/* Bring up the panel itself: TFT, rotation, backlight. SEPARATE from
 * cyd_ui_init() on purpose -- that one is pure state and runs in the host
 * tests, where there is no display to initialise. Keeping the hardware out of
 * it is what lets sim/test_cyd_ui.c drive all five screens on a PC. */
void cyd_ui_backend_init(void);

/* Backlight, 0-100. Called by the caller's idle logic, not from inside the UI:
 * dimming is a policy decision about how long the panel has been untouched,
 * and the screen model has no clock. */
void cyd_ui_set_backlight(uint8_t pct);

/* Read a touch, mapped into the 320x240 LAYOUT coordinates cyd_ui_touch()
 * expects. Returns false when the panel is not being touched.
 *
 * NOT CALIBRATED YET -- the raw-to-screen constants are generic defaults.
 * Touch the four corners with board_probe and set them from what it prints,
 * or the buttons will not be where they are drawn. */
bool cyd_ui_touch_read(int *x, int *y);

/* ---- touch edge detection, extracted so it can be TESTED ---------------
 *
 * This lived inline in main.cpp's loop and was wrong twice in one hour: first
 * with no edge detection at all (a held press walked through the confirm
 * screen and rebooted the miner), then with a debounce that re-armed its own
 * timer every iteration, so the release never fired and the panel accepted
 * exactly one touch before going dead.
 *
 * Both were invisible to the test suite because main.cpp cannot be compiled
 * on a PC. Pulling the state machine out here makes the property testable,
 * which is the only reason it will stay correct. */
typedef struct {
    bool     pressed;    /* debounced: a finger is down                    */
    uint32_t up_at;      /* when the raw signal first went up; 0 = not timing */
} cyd_touch_edge_t;

typedef enum {
    CYD_TOUCH_NONE = 0,
    CYD_TOUCH_PRESS,     /* dispatch a touch at this instant */
    CYD_TOUCH_RELEASE    /* tell the model the finger lifted  */
} cyd_touch_ev_t;

void cyd_touch_edge_init(cyd_touch_edge_t *e);

/* Feed the raw touch state and a millisecond clock; get at most one event.
 *
 * PRESS fires once per physical press, on the rising edge. RELEASE fires once
 * the raw signal has been up for `debounce_ms` -- resistive panels chatter,
 * and an undebounced release reads as lift-then-press, which is a second
 * dispatch and puts the reboot path back. */
cyd_touch_ev_t cyd_touch_edge_update(cyd_touch_edge_t *e, bool down,
                                     uint32_t now_ms, uint32_t debounce_ms);

/* Draw. Called on a fresh status or a touch, not free-running: a full repaint
 * every frame is wasted power on a panel that changes once a second, and this
 * is sitting on top of a miner where the power budget is not free. */
void cyd_ui_draw(cyd_ui_t *ui, const cyd_status_t *st);

/* The firmware-update screen. `err` NULL or "" while the transfer is running;
 * set it to show the failure instead of the bar. Takes over the display
 * because the normal screen would otherwise sit frozen for the minute the
 * update takes, which is exactly when someone reaches for the power. */
void cyd_ui_draw_ota(int pct, const char *err);

/* Touch. Returns the action to carry out, or CYD_ACTION_NONE. Deliberately
 * does NOT call the link itself -- the caller owns that, so this stays
 * testable off-hardware and the UI cannot quietly acquire side effects. */
cyd_action_t cyd_ui_touch(cyd_ui_t *ui, int x, int y);

/* Tell the model the finger has lifted. Until this is called after a screen
 * change, cyd_ui_touch() cannot return an action -- so a single held press
 * can never walk through a confirm screen, however many times the caller
 * polls it. Call it on the falling edge. */
void cyd_ui_touch_release(cyd_ui_t *ui);

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

#ifdef __cplusplus
}
#endif

#endif /* CYD_UI_H */
