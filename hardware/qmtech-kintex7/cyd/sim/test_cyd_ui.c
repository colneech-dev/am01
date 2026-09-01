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

/* Touch the middle of a rect -- what a finger does. Touching corners would
 * pass while a rect was one pixel wide. */
static cyd_action_t tap(cyd_ui_t *ui, cyd_rect_t r)
{
    return cyd_ui_touch(ui, r.x + r.w / 2, r.y + r.h / 2);
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
            }
        }
        ok(!leaked,
           "NO single touch anywhere on the panel can trigger an action");
    }

    /* Two touches should not manage it either, from GLANCE. */
    {
        int leaked = 0;
        for (int y = 0; y < CYD_LAYOUT_H; y += 6) {
            for (int x = 0; x < CYD_LAYOUT_W; x += 6) {
                cyd_ui_init(&ui);
                cyd_ui_touch(&ui, x, y);
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

    printf("\n");
    if (errors == 0) printf("=== ALL %d CHECKS PASSED ===\n", checks);
    else             printf("=== %d of %d CHECK(S) FAILED ===\n", errors, checks);
    return errors ? 1 : 0;
}
