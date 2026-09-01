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

static inline int cyd_rect_hit(cyd_rect_t r, int x, int y)
{
    return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h;
}

#endif /* CYD_UI_LAYOUT_H */
