/*
 * cyd_ui.c -- screen model and touch handling. NO DRAWING.
 *
 * Split from cyd_ui_draw.cpp deliberately, and the split is along the line
 * that makes this testable: everything here is a pure function of the UI
 * state and a touch coordinate, so sim/test_cyd_ui.c drives the entire
 * navigation model -- including the confirm guards -- on a PC in
 * milliseconds, with no panel and no ESP32.
 *
 * That matters most for the CONFIRM flow. "Can a single stray touch reboot
 * the miner" is the one question in this file with a real cost attached, and
 * it is not a question you want to answer by poking a screen and watching
 * whether the board goes down.
 *
 * cyd_ui_touch() returns an action; it never performs one. The caller in
 * main.cpp owns the side effects. If that inverts, this stops being testable
 * and the UI quietly acquires the ability to reboot the miner from inside a
 * hit-test.
 */

#include "cyd_ui.h"
#include "cyd_ui_layout.h"

#include <string.h>
#include <stdio.h>

/* Dim level steps in 10s: fine-grained control here is fiddly on a resistive
 * panel and nobody needs 63% backlight. */
#define DIM_STEP 10
#define DIM_MIN  0
#define DIM_MAX  100

/* Timeout steps: off, then 15s up to 5 minutes. 0 means never dim, which has
 * to remain reachable -- someone bench-testing wants the screen to stay up. */
static const uint32_t TMO_STEPS[] = { 0, 15, 30, 60, 120, 300 };
#define TMO_N ((int)(sizeof(TMO_STEPS) / sizeof(TMO_STEPS[0])))

void cyd_ui_init(cyd_ui_t *ui)
{
    if (!ui)
        return;

    memset(ui, 0, sizeof(*ui));
    ui->screen = CYD_SCREEN_GLANCE;
    ui->pending = CYD_ACTION_NONE;

    /* Defaults: dim to 20% after a minute. A miner runs 24/7 in a room
     * someone may sleep in, and a panel at full brightness all night is a
     * nuisance -- but a panel that goes fully dark is one you cannot glance
     * at, so the floor is dim rather than off. */
    ui->dim_level = 20;
    ui->dim_timeout_s = 60;

    /* Almost every stratum pool ignores the password and the
     * convention is "x". Defaulting it saves typing the one field
     * that never varies, on a keyboard where typing is expensive --
     * and SAVE refuses to send an empty one. */
    ui->pool_pass[0] = 'x';
    ui->pool_pass[1] = 0;
    ui->last_touch_ms = 0;
    ui->link_down = false;
}

static int tmo_index(uint32_t v)
{
    for (int i = 0; i < TMO_N; i++)
        if (TMO_STEPS[i] == v)
            return i;
    return 2;   /* not one of the steps -- snap to 30s */
}

void cyd_touch_edge_init(cyd_touch_edge_t *e)
{
    if (e) { e->pressed = false; e->up_at = 0; }
}

cyd_touch_ev_t cyd_touch_edge_update(cyd_touch_edge_t *e, bool down,
                                     uint32_t now_ms, uint32_t debounce_ms)
{
    if (!e)
        return CYD_TOUCH_NONE;

    if (down) {
        /* Any contact cancels a pending release, so chatter during a press
         * cannot produce a spurious lift. */
        e->up_at = 0;
        if (!e->pressed) {
            e->pressed = true;
            return CYD_TOUCH_PRESS;
        }
        return CYD_TOUCH_NONE;
    }

    if (!e->pressed)
        return CYD_TOUCH_NONE;

    if (e->up_at == 0) {
        /* Start timing ONCE. Re-assigning this on every up iteration -- which
         * the first version of this did, inline in main.cpp -- means the
         * elapsed time never grows and the release never fires. */
        e->up_at = now_ms ? now_ms : 1;   /* 0 is the "not timing" sentinel */
        return CYD_TOUCH_NONE;
    }

    if (now_ms - e->up_at >= debounce_ms) {
        e->pressed = false;
        e->up_at   = 0;
        return CYD_TOUCH_RELEASE;
    }
    return CYD_TOUCH_NONE;
}

void cyd_ui_touch_release(cyd_ui_t *ui)
{
    if (ui)
        ui->needs_release = false;
}

/* ---- POOL / KEYBOARD helpers ------------------------------------------ */

/* Lowercase base layout. Shift affects LETTERS ONLY: a wallet address is
 * base58 (mixed case, no punctuation to shift into) and a hostname wants
 * . - _ : unshifted, so a full symbol layer would be four keys nobody would
 * ever press. */
static const char KB_ROWS_LC[CYD_KB_ROWS][CYD_KB_COLS + 1] = {
    "1234567890",
    "qwertyuiop",
    "asdfghjkl.",
    "zxcvbnm-_:"
};

char cyd_ui_kb_char(int col, int row, bool shift)
{
    if (col < 0 || col >= CYD_KB_COLS || row < 0 || row >= CYD_KB_ROWS)
        return 0;
    char c = KB_ROWS_LC[row][col];
    if (shift && c >= 'a' && c <= 'z')
        c = (char)(c - 'a' + 'A');
    return c;
}

char *cyd_ui_field(cyd_ui_t *ui, cyd_field_t f, size_t *cap)
{
    if (!ui)
        return NULL;
    switch (f) {
    case CYD_FIELD_HOST:   if (cap) *cap = CYD_POOL_HOST_MAX;   return ui->pool_host;
    case CYD_FIELD_PORT:   if (cap) *cap = CYD_POOL_PORT_MAX;   return ui->pool_port;
    case CYD_FIELD_WORKER: if (cap) *cap = CYD_POOL_WORKER_MAX; return ui->pool_worker;
    case CYD_FIELD_PASS:   if (cap) *cap = CYD_POOL_PASS_MAX;   return ui->pool_pass;
    case CYD_FIELD_SSID:   if (cap) *cap = CYD_WIFI_SSID_MAX;   return ui->wifi_ssid;
    case CYD_FIELD_PSK:    if (cap) *cap = CYD_WIFI_PSK_MAX;    return ui->wifi_psk;
    default: return NULL;
    }
}

void cyd_ui_pool_sync(cyd_ui_t *ui, const cyd_status_t *st)
{
    if (!ui || !st)
        return;
    /* NEVER while the user is editing. A status arrives once a second and
     * would otherwise overwrite half-typed input mid-keystroke. */
    /* CONFIRM TOO -- and that omission was the expensive one.
     *
     * needs_release forces the user to lift and re-press before YES, so CONFIRM
     * is on screen for at least one status tick. That status arrived, this
     * function ran, found a colon in st->pool and overwrote pool_host and
     * pool_port with the miner's CURRENT values. YES then sent set_pool with
     * the OLD host and port and the NEW worker -- written to /boot, surviving a
     * reflash, with nothing on screen to say the host was not the one typed.
     * Shares would go to the old pool under a worker that may not exist there. */
    if (ui->screen == CYD_SCREEN_POOL || ui->screen == CYD_SCREEN_KEYBOARD ||
        ui->screen == CYD_SCREEN_WIFI || ui->screen == CYD_SCREEN_CONFIRM)
        return;

    /* status carries "host:port" and no worker, so only these two can be
     * prefilled -- the worker has to be typed, there is nowhere to get it
     * from. Split on the LAST colon so an IPv6 literal does not lose its
     * tail. */
    const char *colon = NULL;
    for (const char *q = st->pool; *q; q++)
        if (*q == ':')
            colon = q;
    if (!colon)
        return;
    size_t hl = (size_t)(colon - st->pool);
    if (hl == 0 || hl >= CYD_POOL_HOST_MAX)
        return;
    memcpy(ui->pool_host, st->pool, hl);
    ui->pool_host[hl] = 0;
    snprintf(ui->pool_port, CYD_POOL_PORT_MAX, "%s", colon + 1);
}

static cyd_action_t touch_inner(cyd_ui_t *ui, int x, int y);

cyd_action_t cyd_ui_touch(cyd_ui_t *ui, int x, int y)
{
    if (!ui)
        return CYD_ACTION_NONE;

    cyd_screen_t before = ui->screen;
    cyd_action_t act = touch_inner(ui, x, y);

    /* ANY screen change re-arms the release requirement. Doing it here rather
     * than in each transition means a new screen cannot be added that quietly
     * forgets it. */
    if (ui->screen != before)
        ui->needs_release = true;
    return act;
}

static cyd_action_t touch_inner(cyd_ui_t *ui, int x, int y)
{

    /* ANY touch counts as activity, including one that hits nothing and
     * including the one that wakes a dimmed panel. Waking on a press but not
     * counting it as activity gives a screen that dims again immediately
     * while being used. */
    ui->last_touch_ms++;   /* caller overwrites with a real timestamp */

    /* THE HAMBURGER IS GLOBAL, checked before the per-screen switch so a new
     * screen cannot be added that quietly loses the only way out of it. Not on
     * MENU, CONFIRM or KEYBOARD, which are modal by design. */
    /* WHITELISTED, not blacklisted. CYD_MENU_BTN {258,198,56,34} OVERLAPS
     * CYD_BTN_RIGHT {240,198,74,34}, so a global check silently swallowed
     * every right-hand button on every screen -- ACTIONS' REBOOT, POOL's SAVE
     * and CONFIRM's YES all became "open the menu". Thirteen model checks
     * caught it; on hardware it would have looked like a panel that ignores
     * its own buttons.
     *
     * These three are exactly the screens odo_ui.c lets you swipe between, and
     * the only ones with nothing of their own in that corner. */
    if ((ui->screen == CYD_SCREEN_GLANCE || ui->screen == CYD_SCREEN_DETAIL ||
         ui->screen == CYD_SCREEN_SETTINGS) &&
        cyd_rect_hit(CYD_MENU_BTN, x, y)) {
        ui->screen = CYD_SCREEN_MENU;
        return CYD_ACTION_NONE;
    }

    switch (ui->screen) {

    /* odo-miner's action sheet. Every item works: WIFI SETUP and RESTART were
     * dead until cyd_proto.h grew set_wifi and restart. */
    case CYD_SCREEN_MENU: {
        static const cyd_screen_t GO[3] = {
            CYD_SCREEN_GLANCE, CYD_SCREEN_DETAIL, CYD_SCREEN_SETTINGS
        };
        for (int i = 0; i < CYD_AS_N; i++) {
            if (!cyd_rect_hit(CYD_AS_ROW(i), x, y))
                continue;
            if (i < 3)       ui->screen = GO[i];
            else if (i == 3) ui->screen = CYD_SCREEN_WIFI;
            else if (i == 4) { ui->pending = CYD_ACTION_RESTART;
                               ui->screen  = CYD_SCREEN_CONFIRM; }
            else if (i == 5) { ui->pending = CYD_ACTION_REBOOT;
                               ui->screen  = CYD_SCREEN_CONFIRM; }
            else             ui->screen = CYD_SCREEN_GLANCE;   /* CANCEL */
            return CYD_ACTION_NONE;
        }
        /* A touch OFF the sheet dismisses it. A modal you cannot leave without
         * hitting the right row is a trap on an uncalibrated touchscreen. */
        ui->screen = CYD_SCREEN_GLANCE;
        return CYD_ACTION_NONE;
    }

    case CYD_SCREEN_WIFI: {
        for (int i = 0; i < CYD_WIFI_ROWS; i++) {
            if (!cyd_rect_hit(CYD_WIFI_ROW(i), x, y))
                continue;
            size_t cap = 0;
            cyd_field_t f = (i == 0) ? CYD_FIELD_SSID : CYD_FIELD_PSK;
            char *buf = cyd_ui_field(ui, f, &cap);
            ui->edit_field = f;
            ui->kb_shift = false;
            if (buf) snprintf(ui->kb_backup, sizeof ui->kb_backup, "%s", buf);
            ui->screen = CYD_SCREEN_KEYBOARD;
            return CYD_ACTION_NONE;
        }
        if (cyd_rect_hit(CYD_WIFI_BACK, x, y)) {
            ui->screen = CYD_SCREEN_GLANCE;
        } else if (cyd_rect_hit(CYD_WIFI_SAVE, x, y)) {
            /* WPA2 is 8..63 characters and the daemon rejects anything else.
             * Refusing HERE means the panel never sends a command that will be
             * silently dropped -- and a headless board that cannot join is one
             * somebody has to walk to. */
            size_t n = strlen(ui->wifi_psk);
            if (ui->wifi_ssid[0] && n >= 8 && n <= 63) {
                ui->pending = CYD_ACTION_SET_WIFI;
                ui->screen  = CYD_SCREEN_CONFIRM;
            }
        }
        return CYD_ACTION_NONE;
    }

    /* GLANCE and DETAIL have NO buttons of their own -- the hamburger above
     * is their only control, as on odo-miner.
     *
     * These used to hit-test CYD_BTN_LEFT/MID/RIGHT, which stopped being drawn
     * when the strip was removed. CYD_BTN_RIGHT spans x 240..313 and the
     * hamburger covers 258..313, so x 240..257 stayed LIVE BUT INVISIBLE: an
     * 18-pixel strip that silently jumped to ACTIONS. Hit geometry that
     * outlives its drawing is exactly what this file's header warns about. */
    case CYD_SCREEN_GLANCE:
    case CYD_SCREEN_DETAIL:
        return CYD_ACTION_NONE;

    case CYD_SCREEN_SETTINGS:
        if (cyd_rect_hit(CYD_SET_DIM_MINUS, x, y)) {
            ui->dim_level = (uint8_t)(ui->dim_level >= DIM_MIN + DIM_STEP
                                      ? ui->dim_level - DIM_STEP : DIM_MIN);
        } else if (cyd_rect_hit(CYD_SET_DIM_PLUS, x, y)) {
            ui->dim_level = (uint8_t)(ui->dim_level <= DIM_MAX - DIM_STEP
                                      ? ui->dim_level + DIM_STEP : DIM_MAX);
        } else if (cyd_rect_hit(CYD_SET_TMO_MINUS, x, y)) {
            int i = tmo_index(ui->dim_timeout_s);
            if (i > 0) ui->dim_timeout_s = TMO_STEPS[i - 1];
        } else if (cyd_rect_hit(CYD_SET_TMO_PLUS, x, y)) {
            int i = tmo_index(ui->dim_timeout_s);
            if (i < TMO_N - 1) ui->dim_timeout_s = TMO_STEPS[i + 1];
        } else if (cyd_rect_hit(CYD_BTN_LEFT, x, y)) {
            ui->screen = CYD_SCREEN_GLANCE;
        } else if (cyd_rect_hit(CYD_BTN_MID, x, y)) {
            /* The only route to ACTIONS now that GLANCE has no strip. MID, not
             * RIGHT: CYD_BTN_RIGHT overlaps the hamburger, and putting a
             * control under it is how the invisible strip happened. */
            ui->screen = CYD_SCREEN_ACTIONS;
        }
        return CYD_ACTION_NONE;

    case CYD_SCREEN_ACTIONS:
        /* Fan boost returns IMMEDIATELY and does NOT go through
         * CONFIRM. It is reversible and cannot lose work, and routing
         * harmless things through the confirm screen is precisely how
         * people learn to tap YES without reading it. */
        if (cyd_rect_hit(CYD_ACT_FAN, x, y)) {
            ui->fan_boost = !ui->fan_boost;
            return CYD_ACTION_FAN_BOOST;
        }
        if (cyd_rect_hit(CYD_ACT_POOL, x, y)) {
            ui->screen = CYD_SCREEN_POOL;
            return CYD_ACTION_NONE;
        }
        if (cyd_rect_hit(CYD_BTN_LEFT, x, y)) {
            ui->screen = CYD_SCREEN_GLANCE;
        } else if (cyd_rect_hit(CYD_BTN_MID, x, y)) {
            ui->pending = CYD_ACTION_RESET_STATS;
            ui->screen  = CYD_SCREEN_CONFIRM;
        } else if (cyd_rect_hit(CYD_BTN_RIGHT, x, y)) {
            ui->pending = CYD_ACTION_REBOOT;
            ui->screen  = CYD_SCREEN_CONFIRM;
        }
        /* NOTHING is returned from this screen. Both destructive actions go
         * via CONFIRM; there is no path from one touch to an effect. */
        return CYD_ACTION_NONE;

    case CYD_SCREEN_CONFIRM:
        if (cyd_rect_hit(CYD_CONFIRM_YES, x, y)) {
            /* THE FINGER MUST HAVE LIFTED since CONFIRM opened. Without this,
             * one held press on the right-hand button walks
             * GLANCE -> ACTIONS -> CONFIRM -> YES, because CYD_CONFIRM_YES is
             * the same rectangle as ACTIONS' REBOOT button -- a reboot in
             * milliseconds with the confirm screen never seen. */
            if (ui->needs_release)
                return CYD_ACTION_NONE;
            cyd_action_t act = ui->pending;
            /* Cleared BEFORE returning, so a second YES cannot repeat it --
             * a double-tap on a reboot confirm should reboot once. */
            ui->pending = CYD_ACTION_NONE;
            ui->screen  = CYD_SCREEN_GLANCE;
            return act;
        }
        if (cyd_rect_hit(CYD_CONFIRM_NO, x, y)) {
            ui->pending = CYD_ACTION_NONE;
            ui->screen  = CYD_SCREEN_ACTIONS;
            return CYD_ACTION_NONE;
        }
        /* A touch anywhere ELSE on a confirm screen does nothing at all --
         * it does not dismiss and it does not confirm. Dismissing on a stray
         * touch would be fine; confirming would not, and treating "outside"
         * as either invites getting it the wrong way round later. */
        return CYD_ACTION_NONE;

    case CYD_SCREEN_POOL: {
        for (int i = 0; i < CYD_POOL_ROWS; i++) {
            if (cyd_rect_hit(CYD_POOL_ROW(i), x, y)) {
                size_t cap = 0;
                char *buf = cyd_ui_field(ui, (cyd_field_t)i, &cap);
                ui->edit_field = (cyd_field_t)i;
                ui->kb_shift = false;
                if (buf)
                    snprintf(ui->kb_backup, sizeof ui->kb_backup, "%s", buf);
                ui->screen = CYD_SCREEN_KEYBOARD;
                return CYD_ACTION_NONE;
            }
        }
        if (cyd_rect_hit(CYD_POOL_BACK, x, y)) {
            ui->screen = CYD_SCREEN_ACTIONS;
        } else if (cyd_rect_hit(CYD_POOL_SAVE, x, y)) {
            /* Refuse an incomplete pool HERE rather than sending it. The
             * daemon rejects empty host/worker/pass, and a command dropped
             * silently at the far end is indistinguishable from a dead
             * panel -- which is the bug this whole link already had once. */
            if (ui->pool_host[0] && ui->pool_port[0] &&
                ui->pool_worker[0] && ui->pool_pass[0]) {
                ui->pending = CYD_ACTION_SET_POOL;
                ui->screen  = CYD_SCREEN_CONFIRM;
            }
        }
        return CYD_ACTION_NONE;
    }

    case CYD_SCREEN_KEYBOARD: {
        size_t cap = 0;
        char *buf = cyd_ui_field(ui, ui->edit_field, &cap);
        if (!buf || cap == 0) {           /* cannot happen; fail closed */
            ui->screen = CYD_SCREEN_POOL;
            return CYD_ACTION_NONE;
        }
        /* Back to WHICHEVER editor opened the keyboard -- hard-coding POOL
         * would strand anyone editing WiFi on the wrong screen. */
        cyd_screen_t home = (ui->edit_field == CYD_FIELD_SSID ||
                             ui->edit_field == CYD_FIELD_PSK)
                          ? CYD_SCREEN_WIFI : CYD_SCREEN_POOL;
        if (cyd_rect_hit(CYD_KB_OK, x, y)) {
            ui->screen = home;
            return CYD_ACTION_NONE;
        }
        if (cyd_rect_hit(CYD_KB_CANCEL, x, y)) {
            snprintf(buf, cap, "%s", ui->kb_backup);    /* discard the edit */
            ui->screen = home;
            return CYD_ACTION_NONE;
        }
        if (cyd_rect_hit(CYD_KB_SHIFT, x, y)) {
            ui->kb_shift = !ui->kb_shift;
            return CYD_ACTION_NONE;
        }
        if (cyd_rect_hit(CYD_KB_BKSP, x, y)) {
            size_t n = strlen(buf);
            if (n)
                buf[n - 1] = 0;
            return CYD_ACTION_NONE;
        }
        for (int r = 0; r < CYD_KB_ROWS; r++) {
            for (int c = 0; c < CYD_KB_COLS; c++) {
                if (!cyd_rect_hit(CYD_KB_KEY(c, r), x, y))
                    continue;
                char ch = cyd_ui_kb_char(c, r, ui->kb_shift);
                if (!ch)
                    return CYD_ACTION_NONE;
                /* A non-numeric port is a pool you cannot reach, and the
                 * daemon would reject it -- so do not let it be typed. */
                if (ui->edit_field == CYD_FIELD_PORT &&
                    (ch < '0' || ch > '9'))
                    return CYD_ACTION_NONE;
                size_t n = strlen(buf);
                if (n + 1 < cap) {
                    buf[n] = ch;
                    buf[n + 1] = 0;
                }
                ui->kb_shift = false;     /* one-shot, like a real keyboard */
                return CYD_ACTION_NONE;
            }
        }
        return CYD_ACTION_NONE;
    }

    default:
        ui->screen = CYD_SCREEN_GLANCE;
        return CYD_ACTION_NONE;
    }
}
