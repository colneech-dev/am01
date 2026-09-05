/*
 * cyd_ui_layout.h -- screen geometry, defined ONCE.
 *
 * Both halves of the UI include this: cyd_ui.c hit-tests touches against these
 * rectangles, and cyd_ui_draw.cpp paints buttons into them.
 *
 * THAT SHARING IS THE ENTIRE POINT. If the drawn rectangle and the hit rectangle
 * are written out separately they drift, and the failure mode is a button that
 * responds a few pixels away from where it is painted -- which presents as an
 * unreliable touchscreen, sends you looking at the XPT2046, and is invisible in
 * the source because both numbers look fine on their own. The reference UI this
 * is ported from keeps its rects in one place for the same reason.
 *
 * Geometry follows odo-miner-cyclonev/sw/odo-ui: 320x240 landscape, a button
 * row 42px from the bottom, 34px tall.
 */

#ifndef CYD_UI_LAYOUT_H
#define CYD_UI_LAYOUT_H

typedef struct {
    int x, y, w, h;
} cyd_rect_t;

/* Panel, landscape. Matches CYD_W/CYD_H in cyd_ui.h. */
#define CYD_LAYOUT_W 320
#define CYD_LAYOUT_H 240

/* Button row along the bottom. */
#define CYD_BTN_H    34
#define CYD_BTN_Y    (CYD_LAYOUT_H - 42)

/* Three buttons: one wide on the left, two narrow. The wide one carries the
 * primary action on each screen, which is why it is the easiest to hit. */
#define CYD_BTN_LEFT   ((cyd_rect_t){   6, CYD_BTN_Y, 148, CYD_BTN_H })
#define CYD_BTN_MID    ((cyd_rect_t){ 160, CYD_BTN_Y,  74, CYD_BTN_H })
#define CYD_BTN_RIGHT  ((cyd_rect_t){ 240, CYD_BTN_Y,  74, CYD_BTN_H })

/* Content area above the buttons. */
#define CYD_CONTENT_Y0 30
#define CYD_CONTENT_Y1 (CYD_BTN_Y - 6)

/* Settings screen: two rows, each with a - and a + control.
 *
 * 44px squares. That is larger than they need to look, and deliberately so:
 * this is a RESISTIVE panel operated by a fingertip, and the usual 24px web
 * affordance is not reliably hittable. Undersized controls on a resistive
 * screen read as a broken digitiser. */
#define CYD_SET_BTN 44
#define CYD_SET_ROW0_Y 70
#define CYD_SET_ROW1_Y 130

#define CYD_SET_DIM_MINUS  ((cyd_rect_t){ 190, CYD_SET_ROW0_Y, CYD_SET_BTN, CYD_SET_BTN })
#define CYD_SET_DIM_PLUS   ((cyd_rect_t){ 250, CYD_SET_ROW0_Y, CYD_SET_BTN, CYD_SET_BTN })
#define CYD_SET_TMO_MINUS  ((cyd_rect_t){ 190, CYD_SET_ROW1_Y, CYD_SET_BTN, CYD_SET_BTN })
#define CYD_SET_TMO_PLUS   ((cyd_rect_t){ 250, CYD_SET_ROW1_Y, CYD_SET_BTN, CYD_SET_BTN })

/* Confirm screen: YES is deliberately the RIGHT-hand button and NO the wide
 * left one, so the easy target is the harmless one. A confirm dialog whose
 * destructive option is the most convenient to hit is not a guard. */
#define CYD_CONFIRM_NO   CYD_BTN_LEFT
#define CYD_CONFIRM_YES  CYD_BTN_RIGHT

/* ---- ACTIONS: fan boost ------------------------------------------------
 *
 * In the CONTENT area, not the button row, and NOT behind CONFIRM. Boosting a
 * fan is reversible and harmless -- guarding it the way a reboot is guarded
 * would teach the habit of tapping through confirm screens, which is exactly
 * what makes the reboot guard worthless. */
#define CYD_ACT_FAN  ((cyd_rect_t){  20, 108, 130, 40 })
#define CYD_ACT_POOL ((cyd_rect_t){ 170, 108, 130, 40 })

/* ---- POOL editor -------------------------------------------------------
 *
 * Four tappable rows -- host, port, worker, password -- each opening the
 * keyboard. 37px pitch keeps the last row clear of the button strip at
 * CYD_BTN_Y (155 + 32 = 187, buttons start at 198). */
#define CYD_POOL_ROWS  4
#define CYD_POOL_ROW_H 32
#define CYD_POOL_ROW(i) ((cyd_rect_t){ 8, 44 + (i) * 37, 304, CYD_POOL_ROW_H })
/* WIFI SETUP: two rows, same pitch as the pool editor so the two editors
 * feel identical -- they share the keyboard, so they should. */
#define CYD_WIFI_ROWS 2
#define CYD_WIFI_ROW(i) ((cyd_rect_t){ 8, 44 + (i) * 37, 304, CYD_POOL_ROW_H })
/* SCAN sits between BACK and SAVE. The WIFI screen has only two rows,
 * so there is room for a third control without crowding. */
#define CYD_WIFI_SCAN  ((cyd_rect_t){ 120, CYD_BTN_Y, 80, 34 })
#define CYD_WIFI_BACK  CYD_BTN_LEFT
#define CYD_WIFI_SAVE  CYD_BTN_RIGHT

/* The picker: one row per network, plus BACK. */
#define CYD_WL_ROWS 6
#define CYD_WL_ROW(i) ((cyd_rect_t){ 8, 44 + (i) * 25, 304, 23 })
#define CYD_WL_BACK  CYD_BTN_LEFT
#define CYD_WL_AGAIN ((cyd_rect_t){ 120, CYD_BTN_Y, 80, 34 })

#define CYD_POOL_BACK  CYD_BTN_LEFT
#define CYD_POOL_SAVE  CYD_BTN_RIGHT

/* ---- KEYBOARD ----------------------------------------------------------
 *
 * 10 x 4 character grid plus a control row. Keys are 31 x 34, which is about
 * as small as a resistive panel and a fingertip can manage -- and note the
 * touch constants are NOT CALIBRATED yet (see cyd_ui_touch_read), so until
 * they are, expect to miss. Calibration matters far more here than anywhere
 * else in this UI: every other screen has at most four targets. */
#define CYD_KB_COLS 10
#define CYD_KB_ROWS 4
#define CYD_KB_X0    5

/* THE EDIT FIELD, between the header rule (y=38) and the keys.
 *
 * The value used to be drawn at y=26 -- inside the 0..36 header band -- so it
 * overlapped the title and read as part of the chrome rather than as the thing
 * being typed. Its own bordered row is what makes it obvious. */
#define CYD_KB_FIELD ((cyd_rect_t){ 5, 41, CYD_LAYOUT_W - 10, 19 })

/* The reveal toggle, at the right-hand end of the field it applies to.
 * On the field rather than in the control row because it is a property
 * of what is being shown, and because that row is already full. */
#define CYD_KB_EYE   ((cyd_rect_t){ CYD_LAYOUT_W - 51, 41, 46, 19 })

/* Keys start 4px lower and are 2px shorter than they were, which is what pays
 * for the field row: 62 + 4*34 = 198, clear of the control row at 202. */
#define CYD_KB_Y0   62
#define CYD_KB_KW   31
#define CYD_KB_KH   32
#define CYD_KB_PITCH_Y 34
#define CYD_KB_KEY(c, r) ((cyd_rect_t){ CYD_KB_X0 + (c) * CYD_KB_KW,                                         CYD_KB_Y0 + (r) * CYD_KB_PITCH_Y,                                         CYD_KB_KW, CYD_KB_KH })
#define CYD_KB_CTRL_Y 202
/* Five controls now, not four. CLEAR earns its place: the worker field is a
 * wallet address plus a name, ~40 characters, and clearing it with backspace
 * is forty taps on a resistive touchscreen. */
/* EIGHT controls across 320px: 37px each on a 40px pitch.
 *
 * That is what settles the labels. "CANCEL" is about 48px at font 2 and
 * overflowed its button; at this width every label has to be three characters
 * or fewer, so it is ESC -- which everyone already reads as cancel -- and BS
 * and DEL for the two kinds of delete.
 *
 * 37px is still a comfortable target on resistive glass; the keys above are
 * 31px and have never been a problem. */
#define CYD_KB_CW 37
#define CYD_KB_CX(i) (2 + (i) * 40)
#define CYD_KB_SHIFT  ((cyd_rect_t){ CYD_KB_CX(0), CYD_KB_CTRL_Y, CYD_KB_CW, 34 })
#define CYD_KB_LEFT   ((cyd_rect_t){ CYD_KB_CX(1), CYD_KB_CTRL_Y, CYD_KB_CW, 34 })
#define CYD_KB_RIGHT  ((cyd_rect_t){ CYD_KB_CX(2), CYD_KB_CTRL_Y, CYD_KB_CW, 34 })
/* BS deletes BACKWARDS (the character before the cursor); DEL deletes
 * FORWARDS (the one at it). Two buttons because they are two different
 * operations, and with only one the other costs a move each way. */
#define CYD_KB_BKSP   ((cyd_rect_t){ CYD_KB_CX(3), CYD_KB_CTRL_Y, CYD_KB_CW, 34 })
#define CYD_KB_FWDDEL ((cyd_rect_t){ CYD_KB_CX(4), CYD_KB_CTRL_Y, CYD_KB_CW, 34 })
#define CYD_KB_CLEAR  ((cyd_rect_t){ CYD_KB_CX(5), CYD_KB_CTRL_Y, CYD_KB_CW, 34 })
#define CYD_KB_CANCEL ((cyd_rect_t){ CYD_KB_CX(6), CYD_KB_CTRL_Y, CYD_KB_CW, 34 })
#define CYD_KB_OK     ((cyd_rect_t){ CYD_KB_CX(7), CYD_KB_CTRL_Y, CYD_KB_CW, 34 })

/* ---- odo-miner navigation ----------------------------------------------
 *
 * ONE hamburger, bottom right, exactly where odo_ui.c puts it -- everything
 * else lives in the modal menu it opens. This replaces the three-button strip
 * this panel used to carry, which was invented here and matches nothing.
 */
#define CYD_MENU_BTN ((cyd_rect_t){ CYD_LAYOUT_W - 62, CYD_LAYOUT_H - 42, 56, 34 })

/* The action sheet: 7 rows, 220x26, 3px gap, centred. odo_ui.c's
 * action_rect() verbatim. */
#define CYD_AS_N      7
#define CYD_AS_W    220
#define CYD_AS_H     26
#define CYD_AS_GAP    3
#define CYD_AS_TOTAL (CYD_AS_N * CYD_AS_H + (CYD_AS_N - 1) * CYD_AS_GAP)
#define CYD_AS_ROW(i) ((cyd_rect_t){ (CYD_LAYOUT_W - CYD_AS_W) / 2, \
                                     (CYD_LAYOUT_H - CYD_AS_TOTAL) / 2 \
                                       + (i) * (CYD_AS_H + CYD_AS_GAP), \
                                     CYD_AS_W, CYD_AS_H })

static inline int cyd_rect_hit(cyd_rect_t r, int x, int y)
{
    return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h;
}

#endif /* CYD_UI_LAYOUT_H */
