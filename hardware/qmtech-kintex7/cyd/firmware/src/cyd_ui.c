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

    switch (ui->screen) {

    case CYD_SCREEN_GLANCE:
        if (cyd_rect_hit(CYD_BTN_LEFT, x, y))  ui->screen = CYD_SCREEN_DETAIL;
        else if (cyd_rect_hit(CYD_BTN_MID, x, y))   ui->screen = CYD_SCREEN_SETTINGS;
        else if (cyd_rect_hit(CYD_BTN_RIGHT, x, y)) ui->screen = CYD_SCREEN_ACTIONS;
        return CYD_ACTION_NONE;

    case CYD_SCREEN_DETAIL:
        if (cyd_rect_hit(CYD_BTN_LEFT, x, y))  ui->screen = CYD_SCREEN_GLANCE;
        else if (cyd_rect_hit(CYD_BTN_MID, x, y))   ui->screen = CYD_SCREEN_SETTINGS;
        else if (cyd_rect_hit(CYD_BTN_RIGHT, x, y)) ui->screen = CYD_SCREEN_ACTIONS;
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
        }
        return CYD_ACTION_NONE;

    case CYD_SCREEN_ACTIONS:
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

    default:
        ui->screen = CYD_SCREEN_GLANCE;
        return CYD_ACTION_NONE;
    }
}
