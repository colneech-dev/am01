/*
 * test_cyd_ui.c -- navigation model and, above all, the confirm guards.
 *
 *   cc -Wall -Wextra -I../firmware/include -I../host \
 *      -o /tmp/t test_cyd_ui.c ../firmware/src/cyd_ui.c && /tmp/t
 *
 * THE QUESTION THIS FILE EXISTS TO ANSWER is whether a single touch can
 * reboot the miner. That is the only thing in the UI with a real cost, and
 * poking a screen to find out means watching a working miner go down to
 * learn that the answer was yes.
 *
 * Because cyd_ui_touch() returns an action rather than performing one, the
 * whole model runs here with no panel, no ESP32 and no link. That property
 * is worth protecting: if the UI ever calls the link directly, this test
 * becomes impossible to write.
 */

#include "cyd_ui.h"
#include "cyd_ui_layout.h"

#include <stdio.h>
#include <string.h>

static int errors = 0, checks = 0;

static void ok(int cond, const char *what)
{
    checks++;
    if (cond) { printf("  PASS  %s\n", what); }
    else      { printf("  FAIL  %s\n", what); errors++; }
}

/* A COMPLETE tap: press, then lift. The lift matters -- the model requires a
 * release before an action can fire after a screen change, so a "tap" that
 * never lifts is a HELD press and is deliberately not the same thing. The
 * held-press tests below exercise that case on purpose.
 *
 * Middle of the rect, because touching corners would pass while a rect was
 * one pixel wide. */
static cyd_action_t tap(cyd_ui_t *ui, cyd_rect_t r)
{
    cyd_action_t a = cyd_ui_touch(ui, r.x + r.w / 2, r.y + r.h / 2);
    cyd_ui_touch_release(ui);
    return a;
}

int main(void)
{
    cyd_ui_t ui;
    cyd_action_t act;

    printf("=== test_cyd_ui ===\n");

    /* ---- defaults ---------------------------------------------------- */
    printf("\n-- init --\n");
    cyd_ui_init(&ui);
    ok(ui.screen == CYD_SCREEN_GLANCE, "starts on GLANCE");
    ok(ui.pending == CYD_ACTION_NONE,  "nothing pending at startup");
    ok(ui.dim_timeout_s > 0,           "dims by default (a miner runs overnight)");
    ok(ui.dim_level > 0,               "dims rather than going dark -- still glanceable");
    ok(!ui.link_down,                  "does not claim the link is down before trying");

    /* ---- navigation --------------------------------------------------- */
    printf("\n-- navigation --\n");
    cyd_ui_init(&ui);
    tap(&ui, CYD_BTN_LEFT);
    ok(ui.screen == CYD_SCREEN_DETAIL, "GLANCE -> DETAIL");
    tap(&ui, CYD_BTN_LEFT);
    ok(ui.screen == CYD_SCREEN_GLANCE, "DETAIL -> GLANCE (the same button goes back)");

    tap(&ui, CYD_BTN_MID);
    ok(ui.screen == CYD_SCREEN_SETTINGS, "GLANCE -> SETTINGS");
    tap(&ui, CYD_BTN_LEFT);
    ok(ui.screen == CYD_SCREEN_GLANCE, "SETTINGS -> GLANCE");

    tap(&ui, CYD_BTN_RIGHT);
    ok(ui.screen == CYD_SCREEN_ACTIONS, "GLANCE -> ACTIONS");
    tap(&ui, CYD_BTN_LEFT);
    ok(ui.screen == CYD_SCREEN_GLANCE, "ACTIONS -> GLANCE");

    /* A touch that hits no control must not navigate. Dead space that
     * silently changes screens is how a panel feels haunted. */
    cyd_ui_init(&ui);
    act = cyd_ui_touch(&ui, 5, 5);
    cyd_ui_touch_release(&ui);
    ok(ui.screen == CYD_SCREEN_GLANCE && act == CYD_ACTION_NONE,
       "a touch on dead space does nothing");

    /* ---- THE CONFIRM GUARDS ------------------------------------------- */
    printf("\n-- confirm guards (the point of this file) --\n");

    cyd_ui_init(&ui);
    tap(&ui, CYD_BTN_RIGHT);                       /* ACTIONS */
    act = tap(&ui, CYD_BTN_RIGHT);                 /* REBOOT  */
    ok(act == CYD_ACTION_NONE,
       "choosing REBOOT returns NO ACTION -- it only opens CONFIRM");
    ok(ui.screen == CYD_SCREEN_CONFIRM, "and lands on CONFIRM");
    ok(ui.pending == CYD_ACTION_REBOOT, "with REBOOT pending");

    act = tap(&ui, CYD_CONFIRM_YES);
    ok(act == CYD_ACTION_REBOOT, "YES returns REBOOT -- two touches, never one");
    ok(ui.pending == CYD_ACTION_NONE,
       "and clears pending, so a double-tap cannot reboot twice");
    ok(ui.screen == CYD_SCREEN_GLANCE, "and returns to GLANCE");

    /* Repeat the YES. If pending were not cleared this fires again. */
    act = tap(&ui, CYD_CONFIRM_YES);
    ok(act == CYD_ACTION_NONE, "a second YES on the way out does nothing");

    /* NO must cancel. */
    cyd_ui_init(&ui);
    tap(&ui, CYD_BTN_RIGHT);
    tap(&ui, CYD_BTN_RIGHT);
    act = tap(&ui, CYD_CONFIRM_NO);
    ok(act == CYD_ACTION_NONE,   "NO returns no action");
    ok(ui.pending == CYD_ACTION_NONE, "NO clears the pending action");
    ok(ui.screen == CYD_SCREEN_ACTIONS, "NO goes back to ACTIONS, not straight out");

    /* A stray touch on CONFIRM must neither confirm nor dismiss. */
    cyd_ui_init(&ui);
    tap(&ui, CYD_BTN_RIGHT);
    tap(&ui, CYD_BTN_RIGHT);
    act = cyd_ui_touch(&ui, CYD_LAYOUT_W / 2, 10);
    cyd_ui_touch_release(&ui);
    ok(act == CYD_ACTION_NONE && ui.screen == CYD_SCREEN_CONFIRM,
       "a touch elsewhere on CONFIRM neither confirms nor dismisses");

    /* Same guard for RESET STATS. */
    cyd_ui_init(&ui);
    tap(&ui, CYD_BTN_RIGHT);
    act = tap(&ui, CYD_BTN_MID);
    ok(act == CYD_ACTION_NONE && ui.pending == CYD_ACTION_RESET_STATS,
       "RESET STATS is guarded the same way");
    act = tap(&ui, CYD_CONFIRM_YES);
    ok(act == CYD_ACTION_RESET_STATS, "and confirms to RESET STATS");

    /* THE STRUCTURAL CLAIM: no single touch from a fresh start returns an
     * action. Swept over the whole panel rather than argued, because this is
     * the property that actually matters and an argument would only cover
     * the cases I thought of. */
    {
        int leaked = 0;
        for (int y = 0; y < CYD_LAYOUT_H; y += 3) {
            for (int x = 0; x < CYD_LAYOUT_W; x += 3) {
                cyd_ui_init(&ui);
                if (cyd_ui_touch(&ui, x, y) != CYD_ACTION_NONE)
                    leaked = 1;
                cyd_ui_touch_release(&ui);
            }
        }
        ok(!leaked,
           "NO single touch anywhere on the panel can trigger an action");
    }

    /* A HELD TOUCH. THIS IS THE ONE THAT WAS MISSING, and its absence let a
     * real bug through to the board.
     *
     * The checks above prove no single CALL triggers an action. The firmware
     * makes one call per loop iteration for as long as a finger is down --
     * tens per press. And CYD_CONFIRM_YES is the SAME RECTANGLE as ACTIONS'
     * REBOOT button (both CYD_BTN_RIGHT), so repeated dispatch at one point
     * walks GLANCE -> ACTIONS -> CONFIRM -> YES and reboots the miner, in
     * milliseconds, with the confirm screen never visible.
     *
     * The model was never wrong; the unit under test was. main.cpp now
     * dispatches on the rising edge only, and this asserts the property that
     * makes that necessary: repeated identical touches must not walk the
     * machine into an action. */
    {
        int leaked = 0;
        for (int y = 0; y < CYD_LAYOUT_H; y += 6) {
            for (int x = 0; x < CYD_LAYOUT_W; x += 6) {
                cyd_ui_init(&ui);
                /* 50 dispatches at ONE point, as a held finger would give. */
                for (int i = 0; i < 50; i++)
                    if (cyd_ui_touch(&ui, x, y) != CYD_ACTION_NONE)
                        leaked = 1;
            }
        }
        ok(!leaked,
           "a HELD touch (50 dispatches at one point) triggers no action");
    }

    /* And specifically the path that bit: the right-hand button is REBOOT on
     * ACTIONS and YES on CONFIRM, so holding it is the dangerous case. */
    {
        cyd_rect_t r = CYD_BTN_RIGHT;
        cyd_ui_init(&ui);
        int fired = 0;
        for (int i = 0; i < 50; i++)
            if (cyd_ui_touch(&ui, r.x + r.w / 2, r.y + r.h / 2)
                    != CYD_ACTION_NONE)
                fired = 1;
        ok(!fired,
           "holding the RIGHT button does not walk GLANCE->ACTIONS->CONFIRM->YES");
    }

    /* Two touches should not manage it either, from GLANCE. */
    {
        int leaked = 0;
        for (int y = 0; y < CYD_LAYOUT_H; y += 6) {
            for (int x = 0; x < CYD_LAYOUT_W; x += 6) {
                cyd_ui_init(&ui);
                cyd_ui_touch(&ui, x, y);
                cyd_ui_touch_release(&ui);
                for (int y2 = 0; y2 < CYD_LAYOUT_H; y2 += 24)
                    for (int x2 = 0; x2 < CYD_LAYOUT_W; x2 += 24) {
                        cyd_ui_t u2 = ui;
                        if (cyd_ui_touch(&u2, x2, y2) != CYD_ACTION_NONE)
                            leaked = 1;
                    }
            }
        }
        ok(!leaked, "nor can any TWO touches -- three is the minimum path");
    }

    /* ---- settings ----------------------------------------------------- */
    printf("\n-- settings --\n");

    cyd_ui_init(&ui);
    tap(&ui, CYD_BTN_MID);
    ok(ui.screen == CYD_SCREEN_SETTINGS, "on SETTINGS");

    uint8_t d0 = ui.dim_level;
    tap(&ui, CYD_SET_DIM_PLUS);
    ok(ui.dim_level > d0, "dim + raises the level");
    tap(&ui, CYD_SET_DIM_MINUS);
    ok(ui.dim_level == d0, "dim - puts it back");

    for (int i = 0; i < 20; i++) tap(&ui, CYD_SET_DIM_PLUS);
    ok(ui.dim_level == 100, "dim + clamps at 100, no wrap");
    for (int i = 0; i < 20; i++) tap(&ui, CYD_SET_DIM_MINUS);
    ok(ui.dim_level == 0, "dim - clamps at 0, no underflow to 255");

    for (int i = 0; i < 20; i++) tap(&ui, CYD_SET_TMO_MINUS);
    ok(ui.dim_timeout_s == 0, "timeout - reaches 0 = never dim, and stops");
    for (int i = 0; i < 20; i++) tap(&ui, CYD_SET_TMO_PLUS);
    ok(ui.dim_timeout_s == 300, "timeout + clamps at the longest step");

    /* ---- layout sanity ------------------------------------------------ */
    printf("\n-- layout --\n");

    /* Overlapping buttons mean a touch lands on whichever the code tests
     * first -- which works until the order changes. */
    {
        cyd_rect_t a = CYD_BTN_LEFT, b = CYD_BTN_MID, c = CYD_BTN_RIGHT;
        ok(a.x + a.w <= b.x, "LEFT and MID do not overlap");
        ok(b.x + b.w <= c.x, "MID and RIGHT do not overlap");
        ok(c.x + c.w <= CYD_LAYOUT_W, "RIGHT is on the panel");
        ok(CYD_BTN_Y + CYD_BTN_H <= CYD_LAYOUT_H, "the button row is on the panel");
    }
    {
        /* The destructive option must not be the easiest target. */
        cyd_rect_t yes = CYD_CONFIRM_YES, no = CYD_CONFIRM_NO;
        ok(yes.w <= no.w,
           "CONFIRM's YES is no larger than NO -- the easy target is the safe one");
    }
    {
        cyd_rect_t r[4] = { CYD_SET_DIM_MINUS, CYD_SET_DIM_PLUS,
                            CYD_SET_TMO_MINUS, CYD_SET_TMO_PLUS };
        int big = 1, on = 1;
        for (int i = 0; i < 4; i++) {
            if (r[i].w < 40 || r[i].h < 40) big = 0;
            if (r[i].x + r[i].w > CYD_LAYOUT_W ||
                r[i].y + r[i].h > CYD_LAYOUT_H) on = 0;
        }
        ok(big, "settings controls are >=40px -- hittable on a RESISTIVE panel");
        ok(on,  "settings controls are on the panel");
    }

    /* ================================================================
     * TOUCH EDGE DETECTION. Extracted from main.cpp because it was wrong
     * TWICE in one hour and neither version was visible to any test:
     *
     *   1. no edge detection at all -- a held press walked
     *      GLANCE -> ACTIONS -> CONFIRM -> YES and rebooted the miner
     *   2. a debounce that re-assigned its own start time every iteration,
     *      so the elapsed time never grew, the release never fired, and the
     *      panel accepted exactly ONE touch before going permanently dead
     *
     * The second is what these checks exist for. It is trivially visible here
     * and was invisible on the board until someone pressed the screen twice.
     * ================================================================ */
    printf("\n-- touch edge detection --\n");
    {
        cyd_touch_edge_t e;
        cyd_touch_edge_init(&e);

        ok(cyd_touch_edge_update(&e, false, 1000, 40) == CYD_TOUCH_NONE,
           "no finger, no event");
        ok(cyd_touch_edge_update(&e, true, 1001, 40) == CYD_TOUCH_PRESS,
           "PRESS on the rising edge");

        /* THE HELD PRESS: many polls, exactly one press. */
        int extra = 0;
        for (uint32_t t = 1002; t < 1200; t++)
            if (cyd_touch_edge_update(&e, true, t, 40) != CYD_TOUCH_NONE)
                extra = 1;
        ok(!extra, "holding it produces NO further events");

        /* THE RELEASE MUST ACTUALLY ARRIVE. This is the check that fails
         * against the re-arming-timer bug, where every up iteration reset the
         * start time and RELEASE never came at all. */
        ok(cyd_touch_edge_update(&e, false, 1200, 40) == CYD_TOUCH_NONE,
           "release starts the debounce, no event yet");
        ok(cyd_touch_edge_update(&e, false, 1220, 40) == CYD_TOUCH_NONE,
           "still inside the debounce window");
        ok(cyd_touch_edge_update(&e, false, 1241, 40) == CYD_TOUCH_RELEASE,
           "RELEASE fires once the window elapses");
        ok(cyd_touch_edge_update(&e, false, 1300, 40) == CYD_TOUCH_NONE,
           "and only once");

        /* A SECOND PRESS MUST WORK. The re-arming bug left `pressed` stuck
         * true, so the panel was dead after a single touch. */
        ok(cyd_touch_edge_update(&e, true, 1400, 40) == CYD_TOUCH_PRESS,
           "a SECOND press is detected -- the panel does not go dead");

        /* Chatter during a press must not fake a release. */
        cyd_touch_edge_init(&e);
        cyd_touch_edge_update(&e, true, 2000, 40);
        cyd_touch_edge_update(&e, false, 2010, 40);      /* bounce */
        ok(cyd_touch_edge_update(&e, true, 2015, 40) == CYD_TOUCH_NONE,
           "a bounce mid-press yields neither PRESS nor RELEASE");
        int fired = 0;
        for (uint32_t t = 2016; t < 2100; t++)
            if (cyd_touch_edge_update(&e, true, t, 40) == CYD_TOUCH_RELEASE)
                fired = 1;
        ok(!fired, "and the cancelled release does not arrive later");

        ok(cyd_touch_edge_update(&e, false, 3000, 40) == CYD_TOUCH_NONE &&
           cyd_touch_edge_update(&e, false, 3041, 40) == CYD_TOUCH_RELEASE,
           "a real release after that bounce still works");

        ok(cyd_touch_edge_update(NULL, true, 0, 40) == CYD_TOUCH_NONE,
           "NULL state does not crash");
    }

    printf("\n");
    if (errors == 0) printf("=== ALL %d CHECKS PASSED ===\n", checks);
    else             printf("=== %d of %d CHECK(S) FAILED ===\n", errors, checks);
    return errors ? 1 : 0;
}
