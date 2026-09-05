/*
 * cyd_ui_draw.cpp -- the drawing half of the panel UI.
 *
 * PAIRED WITH cyd_ui.c, which owns the screen model and touch handling and
 * contains no drawing at all. That split is what lets the whole navigation
 * model -- including the confirm guards -- run on a PC in milliseconds
 * (sim/test_cyd_ui.c, 85 checks). Nothing in this file is testable off
 * hardware, which is exactly why as little as possible lives here.
 *
 * BUTTON GEOMETRY COMES FROM cyd_ui_layout.h, the same header cyd_ui.c
 * hit-tests against. Never write a rectangle here that is not from that
 * header: a drawn button that disagrees with its hit rect gives a panel that
 * responds a few pixels from where it looks, which reads as a broken
 * touchscreen and is invisible in the source because both numbers look fine
 * on their own.
 *
 * PALETTE PORTED FROM odo-miner-cyclonev/sw/odo-ui, not chosen here. The
 * point of this panel is that the miner already has a UI; three different
 * vocabularies for the same numbers would be worse than one imperfect one.
 *
 * Values are formatted by cyd_fmt_* (30 checks), never inline. Those
 * functions are where "-1" becomes "--" rather than a fault the board does
 * not have.
 */

#include <Arduino.h>
#include <SPI.h>
#include <TFT_eSPI.h>
#include <XPT2046_Touchscreen.h>

#include <string.h>
#include <math.h>
#include "cyd_bg.h"
#include "cyd_ui.h"
#include "cyd_ui_layout.h"

/* odo-ui's palette, converted from its RGB565() macro. */
static inline uint16_t rgb(uint8_t r, uint8_t g, uint8_t b)
{
    return (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}
#define C_BG      rgb(16, 15, 11)
#define C_PANEL   rgb(26, 24, 18)
/* The honeycomb. Barely above C_BG on purpose: texture, not content. */
#define C_HEX     rgb(38, 34, 25)
#define C_TEXT    rgb(242, 239, 230)
#define C_DIM     rgb(172, 165, 144)
#define C_OK      rgb(70, 200, 120)
#define C_WARN    rgb(224, 123, 58)
#define C_BAD     rgb(229, 86, 74)
#define C_ACCENT  rgb(240, 178, 60)

static TFT_eSPI tft;

/*
 * THE FRAME IS COMPOSED OFF-SCREEN, IN HORIZONTAL BANDS.
 *
 * Drawing straight to the glass means the panel is briefly WRONG on every
 * update -- the header bar is cleared before its text goes back, the progress
 * bar is filled twice, a screen change repaints the whole backdrop -- and each
 * of those is a visible flash. Composing off-screen and pushing the result
 * makes a frame atomic: nothing is ever seen half-drawn, on any screen.
 *
 * WHY BANDS AND NOT ONE FULL-SCREEN CANVAS. Measured on this hardware:
 *
 *     free heap=344704  largest block=110580
 *     320 x 240 x 16bpp needs 153600 CONTIGUOUS bytes
 *
 * There is heap to spare but no single block big enough, and the ESP32-WROOM-32
 * on this board has no PSRAM. A full-screen canvas silently failed to allocate
 * every time, and the fallback was worse than the direct drawing it replaced.
 *
 * 320x120 is 76,800 bytes, which fits with room, and stays true 16-bit -- an
 * 8-bit palette would have quantised the honeycomb into flat blocks, and the
 * honeycomb is the thing transparent text sits on.
 *
 * Composing off-screen is also what makes TRANSPARENT TEXT safe. Text drawn to
 * the glass needs an opaque background to erase what was there before -- those
 * are the black boxes. Every band starts as a fresh copy of the honeycomb, so
 * there is nothing to erase and text need not paint a box.
 */
#define BAND_H 120

static TFT_eSprite band = TFT_eSprite(&tft);
static bool        band_ok;

/*
 * Screen coordinates in, band coordinates out.
 *
 * Every drawing call in this file goes through this rather than naming the
 * sprite, so the band origin lives in exactly one place. When the sprite
 * cannot be allocated at all, `t` points at the display and `yoff` stays 0 --
 * the panel then behaves as it did before any of this, flickering but
 * correct, instead of failing in some new way.
 */
struct Gfx {
    TFT_eSPI *t;
    int       yoff;

    void setTextDatum(uint8_t d)                { t->setTextDatum(d); }
    void setTextColor(uint16_t c)               { t->setTextColor(c); }
    void setTextColor(uint16_t c, uint16_t b)   { t->setTextColor(c, b); }
    void setSwapBytes(bool b)                   { t->setSwapBytes(b); }
    void fillScreen(uint32_t c)                 { t->fillScreen(c); }
    int16_t textWidth(const char *s, uint8_t f) { return t->textWidth(s, f); }

    void drawString(const char *s, int32_t x, int32_t y, uint8_t f)
        { t->drawString(s, x, y - yoff, f); }
    void fillRect(int32_t x, int32_t y, int32_t w, int32_t h, uint32_t c)
        { t->fillRect(x, y - yoff, w, h, c); }
    void drawRect(int32_t x, int32_t y, int32_t w, int32_t h, uint32_t c)
        { t->drawRect(x, y - yoff, w, h, c); }
    void pushImage(int32_t x, int32_t y, int32_t w, int32_t h,
                   const uint16_t *d)
        { t->pushImage(x, y - yoff, w, h, (uint16_t *)d); }
};

static Gfx g = { &tft, 0 };

/* Reported at boot over USB and up the link. Kept because the answer -- that
 * the largest contiguous block is 110,580 bytes -- is the whole reason this
 * file renders in bands, and the next person to try a full-screen canvas
 * should be able to check rather than assume. */
uint32_t g_canvas_diag_heap;
uint32_t g_canvas_diag_maxblk;

/* main.cpp reports this at boot; band_ok is private to this file. */
bool cyd_ui_canvas_ok(void) { return band_ok; }

/* Touch on VSPI -- its own bus, separate from the display's HSPI. Fixed by
 * the ESP32-2432S028R's PCB, and PROVEN on this board by board_probe: leaving
 * TOUCH_CS unset for TFT_eSPI and driving the XPT2046 on a separate SPIClass
 * is what makes touch work at all here. */
#define TOUCH_SCLK   25
#define TOUCH_MOSI   32
#define TOUCH_MISO   39
#define TOUCH_CS_PIN 33
#define TOUCH_IRQ    36

static SPIClass touch_spi(VSPI);
static XPT2046_Touchscreen touch(TOUCH_CS_PIN, TOUCH_IRQ);

/* RAW XPT2046 EXTREMES. NOT CALIBRATED FOR THIS PANEL -- these are the usual
 * defaults, the same ones board_probe carries. Touches observed on the bench
 * landed around raw (1900-2300, 1580-2410), which is consistent with them but
 * covers only the middle of the glass and proves nothing about the corners.
 *
 * Until they are measured the buttons will be APPROXIMATELY where they are
 * drawn, which is the worst kind of wrong for a touchscreen: close enough to
 * look like it works, far enough to miss. Touch all four corners with
 * board_probe and set these from what it prints. */
static const int RAW_X_MIN = 200, RAW_X_MAX = 3700;
static const int RAW_Y_MIN = 240, RAW_Y_MAX = 3800;

/* The display runs at rotation 1 (landscape), so the panel's raw axes are
 * swapped relative to the layout: raw Y runs along screen X. TOUCH_FLIP_*
 * exist because which end of each axis is which cannot be settled without
 * corner readings -- if a press lands mirrored, flip the matching one. */
#define TOUCH_SWAP_XY 1
#define TOUCH_FLIP_X  0
#define TOUCH_FLIP_Y  1

/* Backlight on its own LEDC channel. Channel 1: TFT_eSPI does not use LEDC
 * itself, but Arduino's tone() takes channel 0, and a panel that dims when
 * something beeps would be a memorable bug. */
#define BL_CHANNEL 1

void cyd_ui_backend_init(void)
{
    tft.init();
    /* LANDSCAPE. cyd_ui_layout.h is 320x240 and the hit rects are in those
     * coordinates, so rotation 1 is not cosmetic -- rotation 0 would leave
     * every button drawn in a different place from where it is tested.
     * board_probe uses rotation 0 because it only paints full-screen fills,
     * where it makes no difference. */
    tft.setRotation(1);
    tft.fillScreen(C_BG);

    /* One allocation, held for the life of the panel. Checked, because the
     * full-screen version silently failed and nobody noticed for two builds. */
    band.setColorDepth(16);
    band_ok = (band.createSprite(CYD_LAYOUT_W, BAND_H) != NULL);
    g.t     = band_ok ? (TFT_eSPI *)&band : &tft;
    g.yoff  = 0;

    g_canvas_diag_heap   = ESP.getFreeHeap();
    g_canvas_diag_maxblk = ESP.getMaxAllocHeap();

    ledcSetup(BL_CHANNEL, 5000, 8);
    ledcAttachPin(TFT_BL, BL_CHANNEL);
    ledcWrite(BL_CHANNEL, 255);

    touch_spi.begin(TOUCH_SCLK, TOUCH_MISO, TOUCH_MOSI, TOUCH_CS_PIN);
    touch.begin(touch_spi);
    touch.setRotation(0);      /* raw; the mapping above does the rotation */
}

bool cyd_ui_touch_read(int *x, int *y)
{
    if (!x || !y || !touch.touched())
        return false;

    TS_Point p = touch.getPoint();

    long rx = TOUCH_SWAP_XY ? p.y : p.x;
    long ry = TOUCH_SWAP_XY ? p.x : p.y;
    int  rx_lo = TOUCH_SWAP_XY ? RAW_Y_MIN : RAW_X_MIN;
    int  rx_hi = TOUCH_SWAP_XY ? RAW_Y_MAX : RAW_X_MAX;
    int  ry_lo = TOUCH_SWAP_XY ? RAW_X_MIN : RAW_Y_MIN;
    int  ry_hi = TOUCH_SWAP_XY ? RAW_X_MAX : RAW_Y_MAX;

    long sx = map(rx, rx_lo, rx_hi, 0, CYD_LAYOUT_W - 1);
    long sy = map(ry, ry_lo, ry_hi, 0, CYD_LAYOUT_H - 1);
    if (TOUCH_FLIP_X) sx = (CYD_LAYOUT_W - 1) - sx;
    if (TOUCH_FLIP_Y) sy = (CYD_LAYOUT_H - 1) - sy;

    /* Clamped, not rejected. A press just off the calibrated edge is still a
     * press at the edge, and dropping it would make the outer few pixels of
     * every button dead. */
    *x = (int)constrain(sx, 0, CYD_LAYOUT_W - 1);
    *y = (int)constrain(sy, 0, CYD_LAYOUT_H - 1);
    return true;
}

void cyd_ui_set_backlight(uint8_t pct)
{
    if (pct > 100) pct = 100;
    /* Never fully off. A dark panel on a miner in a cupboard is indis-
     * tinguishable from a dead one, and the point of dimming is to stop it
     * lighting a room, not to hide it. cyd_ui.c's floor is 0, so clamp here
     * where the hardware is. */
    uint32_t duty = (uint32_t)pct * 255u / 100u;
    if (duty < 8) duty = 8;
    ledcWrite(BL_CHANNEL, duty);
}

/* ---- small helpers ---------------------------------------------------- */

static void fill_rect(cyd_rect_t r, uint16_t c)
{
    g.fillRect(r.x, r.y, r.w, r.h, c);
}

/* A button, drawn into its LAYOUT rect. `hot` marks the destructive one. */
static void button(cyd_rect_t r, const char *label, bool hot)
{
    fill_rect(r, hot ? C_BAD : C_PANEL);
    g.drawRect(r.x, r.y, r.w, r.h, hot ? C_BAD : C_ACCENT);
    g.setTextColor(hot ? C_TEXT : C_ACCENT, hot ? C_BAD : C_PANEL);
    g.setTextDatum(MC_DATUM);
    g.drawString(label, r.x + r.w / 2, r.y + r.h / 2, 2);
}

/* label on the left, value right-aligned -- a two-column row. */
static void row(int y, const char *label, const char *value, uint16_t vc)
{
    g.setTextDatum(TL_DATUM);
    g.setTextColor(C_DIM);
    g.drawString(label, 10, y, 2);
    g.setTextDatum(TR_DATUM);
    g.setTextColor(vc);
    g.drawString(value, CYD_LAYOUT_W - 10, y, 2);
}

/* odo_ui.c's 16x16 mark, verbatim: outer ring plus a solid inner hex, flat-top
 * to match the web SVG. Pixel art rather than geometry, because that is what
 * the other panel draws and a mark that is subtly the wrong shape is worse
 * than no mark at all. */
static const char *LOGO_PX[16] = {
    "................",
    "....11111111....",
    "...1........1...",
    "..1..........1..",
    ".1....2222....1.",
    ".1...222222...1.",
    "1...22222222...1",
    "1...22222222...1",
    "1...22222222...1",
    ".1...222222...1.",
    ".1....2222....1.",
    "..1..........1..",
    "...1........1...",
    "....11111111....",
    "................",
    "................",
};

static void logo(int x, int y, int scale)
{
    for (int r = 0; r < 16; r++)
        for (int c = 0; c < 16; c++) {
            char v = LOGO_PX[r][c];
            if (v != '1' && v != '2')
                continue;
            g.fillRect(x + c * scale, y + r * scale, scale, scale, C_ACCENT);
        }
}

/* THE HONEYCOMB, blitted from the real artwork.
 *
 * cyd_bg.h is odo-miner's own bg.png -- already 320x240, so it goes down
 * 1:1 with no scaling and is pixel-for-pixel what the other panel shows.
 *
 * setSwapBytes(true) because TFT_eSPI pushes 16-bit data big-endian to the
 * panel while the array is host order; without it every colour comes out
 * wrong, which on a dark texture reads as "the background is broken" rather
 * than as a byte-order bug. */
static void hexbg(void)
{
    g.setSwapBytes(true);
    g.pushImage(0, 0, CYD_BG_W, CYD_BG_H, CYD_BG);
    g.setSwapBytes(false);
}

/*
 * Put the honeycomb back under ONE rectangle.
 *
 * The alternative -- clearing a field to flat C_BG before redrawing it -- is
 * what the text already does via setTextColor(fg), and it is why the
 * background shows only in the gaps between glyphs. Clearing a whole field
 * box that way would flatten the honeycomb across the box's full width, which
 * is visible as a rectangular hole in the pattern once a string gets shorter.
 *
 * Row by row, because pushImage wants w*h contiguous pixels and CYD_BG is
 * stored full-width; a sub-rectangle is not contiguous. One pushImage per row
 * is still one SPI burst per row and costs microseconds at these sizes.
 */
static void bg_restore(int x, int y, int w, int h)
{
    if (x < 0 || y < 0 || w <= 0 || h <= 0) return;
    if (x + w > CYD_BG_W) w = CYD_BG_W - x;
    if (y + h > CYD_BG_H) h = CYD_BG_H - y;
    if (w <= 0 || h <= 0) return;

    g.setSwapBytes(true);
    for (int row = 0; row < h; row++)
        g.pushImage(x, y + row, w, 1, &CYD_BG[(size_t)(y + row) * CYD_BG_W + x]);
    g.setSwapBytes(false);
}

/*
 * A DYNAMIC FIELD, COMPOSED OFF-SCREEN.
 *
 * The blink was never only the full-screen repaint. Even restoring just the
 * honeycomb under one field left three states visible in sequence --
 * background, then an opaque black text box, then the glyphs -- and the eye
 * caught the middle one every second.
 *
 * So a field is built in a sprite instead: the honeycomb underneath, the text
 * over it with a TRANSPARENT background, and the result pushed as ONE SPI
 * write. Nothing is ever on the glass half-drawn, and the pattern shows
 * through the text because the text no longer paints its own box.
 *
 * setTextColor() with ONE argument is what makes text transparent in
 * TFT_eSPI. The two-argument form is what was drawing the black boxes.
 *
 * If the sprite cannot be allocated the field still draws -- straight to the
 * screen after a bg_restore, flickering as it used to rather than vanishing.
 * g_gfx points at whichever target won; TFT_eSprite derives from TFT_eSPI so
 * the calls are identical either way, and g_ox/g_oy turn field-local
 * coordinates into screen ones for the fallback.
 */
static TFT_eSprite g_spr = TFT_eSprite(&tft);
static TFT_eSPI   *g_gfx = &tft;
static int         g_ox, g_oy, g_fx, g_fy;
static bool        g_spr_live;

static void field_begin(int x, int y, int w, int h)
{
    g_spr.setColorDepth(16);
    if (g_spr.createSprite(w, h)) {
        g_spr.setSwapBytes(true);
        for (int r = 0; r < h; r++)
            g_spr.pushImage(0, r, w, 1,
                            (uint16_t *)&CYD_BG[(size_t)(y + r) * CYD_BG_W + x]);
        g_spr.setSwapBytes(false);
        g_gfx = &g_spr;
        g_ox = 0; g_oy = 0;
        g_fx = x; g_fy = y;
        g_spr_live = true;
    } else {
        bg_restore(x, y, w, h);
        g_gfx = &tft;
        g_ox = x; g_oy = y;
        g_spr_live = false;
    }
}

static void field_end(void)
{
    if (g_spr_live) {
        g_spr.pushSprite(g_fx, g_fy);
        g_spr.deleteSprite();
        g_spr_live = false;
    }
    g_gfx = &tft;
    g_ox = 0;
    g_oy = 0;
}

/* The MINER's wall clock, in the header. A CYD has no RTC and NTP may never
 * have run on it, so this is st->updated passed through -- the same reason
 * odo_ui.c draws the miner's time rather than its own. */
static void draw_clock(uint32_t updated)
{
    if (!updated)
        return;
    char b[8];
    uint32_t tod = updated % 86400u;
    snprintf(b, sizeof b, "%02u:%02u", (unsigned)(tod / 3600u),
             (unsigned)((tod % 3600u) / 60u));
    g.setTextDatum(TR_DATUM);
    g.setTextColor(C_DIM);
    g.drawString(b, CYD_LAYOUT_W - 76, 4, 2);
}

/* ONE hamburger, bottom right, where odo_ui.c puts it. */
static void hamburger(void)
{
    cyd_rect_t r = CYD_MENU_BTN;
    g.drawRect(r.x, r.y, r.w, r.h, C_ACCENT);
    for (int i = 0; i < 3; i++)
        g.fillRect(r.x + 12, r.y + 9 + i * 6, r.w - 24, 3, C_ACCENT);
}

static const char *AS_LABELS[CYD_AS_N] = {
    "GLANCE", "DETAIL", "SETUP", "WIFI SETUP", "RESTART", "REBOOT", "CANCEL"
};

/* WIFI SETUP and RESTART are drawn but INERT, and drawn dim so that is
 * visible.
 *
 * NOTHING IS GREYED ANY MORE. WIFI SETUP and RESTART were dim only because the
 * link had no verb for either; cyd_proto.h now carries set_wifi and restart,
 * the daemon applies both, and every row on the sheet does something. Kept as
 * a function rather than deleted because a menu that grows an unimplemented
 * item again should grey it rather than lie. */
static bool as_enabled(int i)
{
    (void)i;
    return true;
}

static void draw_menu(void)
{
    cyd_rect_t top = CYD_AS_ROW(0), bot = CYD_AS_ROW(CYD_AS_N - 1);
    int pad = 12;
    g.fillRect(top.x - pad, top.y - pad, top.w + 2 * pad,
                 (bot.y + bot.h - top.y) + 2 * pad, C_ACCENT);
    g.fillRect(top.x - pad + 1, top.y - pad + 1, top.w + 2 * pad - 2,
                 (bot.y + bot.h - top.y) + 2 * pad - 2, C_BG);

    for (int i = 0; i < CYD_AS_N; i++) {
        cyd_rect_t r = CYD_AS_ROW(i);
        uint16_t border = (i == 5) ? C_BAD : (i == 6) ? C_PANEL : C_ACCENT;
        uint16_t tc     = (i == 5) ? C_BAD : (i == 6) ? C_TEXT  : C_ACCENT;
        if (!as_enabled(i)) { border = C_PANEL; tc = C_DIM; }
        g.fillRect(r.x, r.y, r.w, r.h, border);
        g.fillRect(r.x + 1, r.y + 1, r.w - 2, r.h - 2, C_PANEL);
        g.setTextDatum(MC_DATUM);
        g.setTextColor(tc);
        g.drawString(AS_LABELS[i], r.x + r.w / 2, r.y + r.h / 2, 2);
    }
}

/*
 * Signal strength, as four bars.
 *
 * Thresholds are the ones that predict whether an association actually holds,
 * not evenly spaced ones: better than -55 is excellent, -65 good, -75 usable,
 * below that marginal. An unknown level (0) draws the outlines only -- saying
 * "no signal" when the truth is "no reading" would be a different claim.
 */
static void wifi_bars(int x, int y, int rssi)
{
    const int n = 4;
    int filled = 0;
    if (rssi != 0) {
        filled = (rssi > -55) ? 4
               : (rssi > -65) ? 3
               : (rssi > -75) ? 2
               : 1;
    }
    for (int i = 0; i < n; i++) {
        int h = 4 + i * 3;                 /* 4, 7, 10, 13 */
        int bx = x + i * 4;
        int by = y + 13 - h;
        if (i < filled)
            g.fillRect(bx, by, 3, h, rssi > -75 ? C_OK : C_WARN);
        else
            g.drawRect(bx, by, 3, h, C_DIM);
    }
}

static void header(const char *title, const cyd_status_t *st, bool link_down)
{
    char b[64];

    g.fillRect(0, 0, CYD_LAYOUT_W, 36, C_PANEL);
    g.fillRect(0, 36, CYD_LAYOUT_W, 2, C_ACCENT);

    logo(4, 2, 2);

    /* ---- the right-hand group, all on ONE line ------------------------
     * Laid out from the right edge inwards, because only the rightmost item
     * has a fixed position -- everything else depends on the width of what is
     * to its right, and the tag is "POOL OK", "OFFLINE" or "MINER DOWN". */
    const char *tag;
    uint16_t    tc;
    if (link_down)           { tag = "MINER DOWN"; tc = C_BAD;  }
    else if (!st->connected) { tag = "OFFLINE";    tc = C_WARN; }
    else                     { tag = "POOL OK";    tc = C_OK;   }

    int right = CYD_LAYOUT_W - 6;
    g.setTextDatum(TR_DATUM);
    g.setTextColor(tc);
    g.drawString(tag, right, 4, 2);
    right -= g.textWidth(tag, 2) + 8;

    /* The miner's wall clock. A CYD has no RTC and NTP may never have run on
     * it, so this is st->updated passed through -- the same reason odo_ui.c
     * draws the miner's time rather than its own. */
    if (st->updated) {
        uint32_t secs = st->updated % 86400u;
        snprintf(b, sizeof b, "%02u:%02u",
                 (unsigned)(secs / 3600u), (unsigned)((secs % 3600u) / 60u));
        g.setTextDatum(TR_DATUM);
        g.setTextColor(C_DIM);
        g.drawString(b, right, 4, 2);
        right -= g.textWidth(b, 2) + 8;
    }

    /* Only when the board has a radio worth reporting on. An ethernet-only
     * miner should not carry a permanently empty signal meter. */
    if (st->wifi_ssid[0] || st->wifi_rssi != 0) {
        right -= 16;
        wifi_bars(right, 4, st->wifi_rssi);
        right -= 8;
    }

    /* ---- the title, in whatever room is left --------------------------
     * ELIDED, because it used to run underneath the clock. "PICK NETWORK" at
     * font 4 is about 170px and the group above starts around 200, so the
     * overlap was not hypothetical -- the clock simply disappeared on the
     * longer screens. */
    const char *shown = (title && title[0]) ? title : "ODO MINER";
    int avail = right - 40;

    /* DROP A FONT SIZE BEFORE DROPPING CHARACTERS.
     *
     * Truncating first gave "PLEASE W" -- which is not a shorter label, it is
     * a broken one. Font 2 is a little over half the width of font 4, so a
     * title that will not fit at 4 usually fits whole at 2, and a complete
     * word in a smaller face reads far better than half a word in a large
     * one. Truncation stays as the last resort for something genuinely
     * enormous. */
    uint8_t font = 4;
    if (g.textWidth(shown, 4) > avail)
        font = 2;

    int maxch = (int)(sizeof b) - 1;
    int n = 0;
    while (shown[n] && n < maxch) {
        snprintf(b, sizeof b, "%.*s", n + 1, shown);
        if (g.textWidth(b, font) > avail)
            break;
        n++;
    }
    snprintf(b, sizeof b, "%.*s", n, shown);

    g.setTextDatum(TL_DATUM);
    g.setTextColor(C_TEXT);
    /* Nudged down at the smaller size so it stays on the header's centre
     * line rather than riding high. */
    g.drawString(b, 40, font == 4 ? 8 : 12, font);
}

/* ---- screens ---------------------------------------------------------- */

/* GLANCE, ported coordinate-for-coordinate from odo_ui.c's draw_glance().
 *
 * odo_ui renders a TTF at scales 1/2/3; TFT_eSPI has bitmap fonts, so the
 * mapping is 1 -> font 2, 2 -> font 4, 3 -> font 6. Font 6 carries digits,
 * '.', ':', 'a', 'p' and 'm' only, so the hashrate NUMBER is drawn in 6 and
 * its unit in 4 beside it -- odo_ui gets both from one TTF call.
 *
 * odo_ui also blits a bg.png behind everything. Not carried over: it would
 * mean embedding a 320x240 RGB565 bitmap (150KB) in flash for a texture, and
 * the flat C_BG underneath it is the same colour. */
static void draw_glance(const cyd_status_t *st, bool link_down)
{
    char b[48];
    (void)link_down;

    /* Everything here draws into the off-screen canvas, which already holds
     * the honeycomb. Text is transparent, so the pattern shows through it. */
    g.setTextDatum(TL_DATUM);
    g.setTextColor(C_DIM);
    g.drawString("HASHRATE", 14, 42, 2);
    g.drawString("SHAPECHANGE IN", 14, 116, 2);

    /* ---- hashrate hero -------------------------------------------------
     * 11px lower than it was: 320px across about 2.24in is ~143dpi, so the
     * 2mm asked for is 11px. Everything below moved with it, and the
     * countdown dropped to font 2, which is what buys the room back. */
    cyd_fmt_hashrate(st->hashrate, b, (int)sizeof b);
    {
        /* Split "82.51 MH/s" so the number can use the big font. */
        char num[24], *sp = strchr(b, ' ');
        const char *unit = "";
        size_t n = sp ? (size_t)(sp - b) : strlen(b);
        if (n >= sizeof num) n = sizeof num - 1;
        memcpy(num, b, n); num[n] = 0;
        if (sp) unit = sp + 1;

        g.setTextColor(C_TEXT);
        g.drawString(num, 14, 65, 6);
        int w = g.textWidth(num, 6);
        g.setTextColor(C_ACCENT);
        g.drawString(unit, 14 + w + 6, 87, 4);
    }

    /* ---- shapechange countdown + progress bar ------------------------- */
    int bar_full = CYD_LAYOUT_W - 28;
    /* st->updated must be non-zero too. Without it a status missing "updated"
     * (get_u32 leaves the field alone on a miss, and g_status starts zeroed)
     * gives left ~= 1.7e9 and the panel proudly announces "20077d 0h 0m".
     * cyd_fmt_epoch_left_at guards this and names the same symptom; DETAIL is
     * correct because it uses the formatter, GLANCE reimplemented it. */
    if (st->epoch && st->updated && st->epoch_next > st->epoch) {
        long left = (long)st->epoch_next - (long)st->updated;
        if (left < 0) left = 0;
        snprintf(b, sizeof b, "%ldd %ldh %ldm",
                 left / 86400, (left % 86400) / 3600, (left % 3600) / 60);
        g.setTextColor(C_TEXT);
        g.drawString(b, 14, 132, 2);

        long total = (long)st->epoch_next - (long)st->epoch;
        long done  = (long)st->updated - (long)st->epoch;
        if (done < 0) done = 0;
        /* Clamp BEFORE multiplying. long is 32-bit here, so bar_full * done
         * overflows once done passes ~7.35M seconds; the negative result was
         * only hidden by the fill > 0 test below, which is luck, not a guard. */
        if (done > total) done = total;
        int fill = (total > 0) ? (int)((long)bar_full * done / total) : 0;
        if (fill > bar_full) fill = bar_full;
        g.fillRect(14, 152, bar_full, 7, C_PANEL);
        if (fill > 0) g.fillRect(14, 152, fill, 7, C_ACCENT);
    } else {
        g.setTextColor(C_DIM);
        g.drawString("loading...", 14, 132, 2);
        g.fillRect(14, 152, bar_full, 7, C_PANEL);
    }

    /* Either the wrong-epoch warning, or the compact summary. Never both:
     * odo_ui.c gives the warning the whole strip because nothing else on the
     * screen matters while every share is being rejected. */
    if (st->bitstream_epoch && st->epoch && st->bitstream_epoch != st->epoch) {
        g.fillRect(6, 164, CYD_LAYOUT_W - 12, 18, C_BAD);
        g.setTextDatum(MC_DATUM);
        g.setTextColor(C_TEXT);
        g.drawString("! WRONG EPOCH - REBOOT !", CYD_LAYOUT_W / 2, 173, 2);
        g.setTextDatum(TL_DATUM);
        /* The hamburger MUST still be drawn. This branch returned before it,
         * so in the one state where the panel is telling you to reboot, the
         * only route to REBOOT was invisible -- GLANCE has no other control. */
        hamburger();
        return;
    }

    /* ---- summary rows -------------------------------------------------
     * THREE rows now, not two. FAN used to share row two, drawn at x=250, and
     * cyd_fmt_fan produces up to "4950rpm 100%" -- about 96px at font 2, which
     * ran off a 320px screen. It gets its own line under TEMP. */
    g.setTextColor(C_DIM);
    g.drawString("SHARES", 14, 166, 2);
    g.drawString("BEST-S", 168, 166, 2);
    g.drawString("TEMP", 14, 184, 2);
    g.drawString("FAN", 14, 202, 2);

    snprintf(b, sizeof b, "%llu", (unsigned long long)st->shares_accepted);
    g.setTextColor(C_TEXT);
    g.drawString(b, 64, 166, 2);

    /* odo_ui.c has fmt_diff(); this tree formats plainly, as its
     * DETAIL screen already did. */
    snprintf(b, sizeof b, "%.3f", st->best_diff_session);
    g.setTextColor(C_ACCENT);
    g.drawString(b, 220, 166, 2);

    /* Through cyd_fmt_temp, not inline. The inline guard accepted temp_c >=
     * -50, so the documented -1 "unknown" sentinel passed it and rendered
     * "-1C" -- which reads as a board fault rather than a missing sensor. The
     * formatter is where -1 becomes "--", and this file's own header says
     * values are never formatted inline. */
    cyd_fmt_temp(st->temp_c, b, (int)sizeof b);
    g.setTextColor(st->temp_c >= 65 ? C_WARN : C_TEXT);
    g.drawString(b, 56, 184, 2);

    unsigned long long total = st->shares_accepted + st->shares_rejected;
    if (total > 0) {
        int pct = (int)(st->shares_accepted * 100ULL / total);
        snprintf(b, sizeof b, "%d%%", pct);
        /* "ACCEPT", not "ACC" -- the share accept rate is the first place a
         * stale bitstream or a sulking pool shows up, and an abbreviation
         * nobody can expand is a number nobody reads. There is room for it
         * now that FAN has its own line. */
        g.setTextColor(C_DIM);
        g.drawString("ACCEPT", 168, 184, 2);
        g.setTextColor(pct >= 90 ? C_OK : pct >= 70 ? C_WARN : C_BAD);
        g.drawString(b, 226, 184, 2);
    }

    /* Gated on fan_rpm but PRINTED fan_duty_pct -- backwards on both halves. A
     * board with no tach pull-up fitted (rpm == -1, which was the real state
     * until 2026-08-30) hid a perfectly good duty reading, and a -1 duty with
     * a working tach printed "-1%". The formatter handles both sentinels. */
    cyd_fmt_fan(st->fan_rpm, st->fan_duty_pct, b, (int)sizeof b);
    g.setTextColor(st->fan_duty_pct > 0 ? C_OK : C_DIM);
    g.drawString(b, 56, 202, 2);

    hamburger();
}

/* d/h/m, the same shape odo_ui.c uses. Local because it is only wanted here
 * and cyd_fmt_* is the tested surface -- adding to that header means adding to
 * its test suite, which is right for a value with edge cases and overkill for
 * three divisions. */
static void dur_fmt(uint32_t secs, char *out, size_t n)
{
    snprintf(out, n, "%ud %uh %um",
             secs / 86400u, (secs % 86400u) / 3600u, (secs % 3600u) / 60u);
}

/* Defined further down, next to the other text helpers. */
static const char *elide(const char *v, char *buf, size_t cap, size_t maxch);

/*
 * DETAIL, laid out like odo_ui.c's draw_detail() -- a TWO-COLUMN grid, not a
 * single list of right-aligned rows.
 *
 * The old version showed seven facts in one column and left out the ones
 * people actually go to this screen for: the pool it is connected to, the
 * address the web UI is on, how many shares have been submitted against how
 * many were found, when the last one landed, and the temperature and fan.
 *
 * Column positions are odo_ui.c's: labels at 14 and 168, values at 68 and
 * 216. Keeping them identical matters -- this panel exists so the miner has
 * ONE visual vocabulary, and a detail screen that arranges the same numbers
 * differently is the sort of small divergence that makes two products out of
 * one.
 */
static void draw_detail(const cyd_status_t *st, uint32_t now)
{
    char b[64], b2[64];
    /* COLUMNS RETUNED FOR THIS FONT. odo_ui.c uses 168/216, but it draws
     * its own face at scale 1; TFT_eSPI's font 2 is wider, so "SBM/FND" at
     * 168 reached 224 and ran into the value column, and a fan string at 216
     * ran off the 320px edge. The right column moves left and the values
     * start further across. */
    /* The right column sits at 144 with its values at 216 -- a 72px gap.
     * "SBM/FND" is seven characters and TFT_eSPI font 2 carries it to
     * about x=204, so at 150/206 the label still touched the value it
     * labels. odo_ui.c gets away with 168/216 because it draws its own
     * narrower face; this font needs the room. */
    const int xL = 12, xLv = 64, xR = 144, xRv = 216;
    /* 17, not 18: nine rows at 42..194 clears the hamburger at 198,
     * and the ninth is what lets the fan have a full-width line. */
    int y = 42;

    /* One left-column pair. */
    #define DROW_L(lbl, val, col) do {                         \
        g.setTextDatum(TL_DATUM);                              \
        g.setTextColor(C_DIM);  g.drawString((lbl), xL, y, 2);  \
        g.setTextColor(col);    g.drawString((val), xLv, y, 2); \
    } while (0)

    /* ...and its right-hand neighbour, on the same line. */
    #define DROW_R(lbl, val, col) do {                         \
        g.setTextDatum(TL_DATUM);                              \
        g.setTextColor(C_DIM);  g.drawString((lbl), xR, y, 2);  \
        g.setTextColor(col);    g.drawString((val), xRv, y, 2); \
    } while (0)

    /* POOL spans the width -- a host:port does not fit in a half. Elided
     * rather than clipped, so it is obvious something was dropped. */
    elide(st->pool[0] ? st->pool : "--", b, sizeof b, 30);
    DROW_L("POOL", b, st->connected ? C_TEXT : C_WARN);
    y += 17;

    /* JOB | SBM/FND -- submitted against found. They differ when the pool is
     * refusing work or the link to it is down, which is exactly the state
     * this screen is opened to diagnose. */
    DROW_L("JOB", st->job_id[0] ? st->job_id : "--", C_TEXT);
    snprintf(b2, sizeof b2, "%llu/%llu",
             (unsigned long long)st->shares_accepted,
             (unsigned long long)st->shares_found);
    DROW_R("SBM/FND", b2, C_TEXT);
    y += 17;

    /* UPTIME | LAST share */
    dur_fmt(st->uptime, b, sizeof b);
    DROW_L("UPTIME", b, C_DIM);
    if (st->last_share && st->updated && st->updated >= st->last_share) {
        dur_fmt(st->updated - st->last_share, b2, sizeof b2);
        DROW_R("LAST", b2, C_TEXT);
    } else {
        DROW_R("LAST", "--", C_DIM);
    }
    y += 17;

    /* IP -- the whole reason anyone reads this screen twice: it is how the
     * web UI is found. Amber when absent, because "no network" is a fault
     * worth noticing rather than a blank. */
    DROW_L("IP", st->ip[0] ? st->ip : "no network",
           st->ip[0] ? C_TEXT : C_WARN);
    y += 17;

    /* EPOCH -- STALE is the loudest thing this screen can say, and it earns
     * it: past the rollover an un-rebuilt bitstream mines nothing but
     * rejects, and every other number here still looks healthy. */
    {
        bool stale = (st->bitstream_epoch && st->epoch &&
                      st->bitstream_epoch != st->epoch);
        cyd_fmt_epoch_left_at(st->epoch_next, now, b, sizeof b);
        DROW_L("EPOCH", stale ? "STALE - REBUILD" : b,
               stale ? C_BAD : C_TEXT);
    }
    y += 17;

    /* BEST-S | BEST-A */
    snprintf(b, sizeof b, "%.3f", st->best_diff_session);
    DROW_L("BEST-S", b, C_ACCENT);
    snprintf(b2, sizeof b2, "%.3f", st->best_diff_alltime);
    DROW_R("BEST-A", b2, C_ACCENT);
    y += 17;

    /* BLOCKS | CORE */
    snprintf(b, sizeof b, "%llu", (unsigned long long)st->blocks_found);
    DROW_L("BLOCKS", b, st->blocks_found ? C_OK : C_DIM);
    DROW_R("CORE", st->core[0] ? st->core : "--", C_DIM);
    y += 17;

    /* TEMP, through the formatter so the -1 "unknown" sentinel renders as
     * "--" rather than as a board fault. */
    cyd_fmt_temp(st->temp_c, b, (int)sizeof b);
    DROW_L("TEMP", b, st->temp_c >= 65 ? C_WARN : C_TEXT);
    y += 17;

    /* FAN gets the WHOLE ROW, so the rpm can be labelled.
     *
     * In the right-hand column it had to be either unlabelled ("100% 4950",
     * which does not say what 4950 is) or off the edge of the glass. Full
     * width has no such constraint -- the same reason POOL and IP span the
     * row. */
    if (st->fan_rpm > 0 && st->fan_duty_pct >= 0)
        snprintf(b2, sizeof b2, "%d rpm   %d%%", st->fan_rpm, st->fan_duty_pct);
    else
        cyd_fmt_fan(st->fan_rpm, st->fan_duty_pct, b2, (int)sizeof b2);
    DROW_L("FAN", b2, st->fan_duty_pct > 0 ? C_OK : C_DIM);

    #undef DROW_L
    #undef DROW_R

    hamburger();
}


static void stepper(int y, const char *label, const char *value,
                    cyd_rect_t minus, cyd_rect_t plus)
{
    g.setTextDatum(TL_DATUM);
    g.setTextColor(C_DIM);
    g.drawString(label, 10, y + 12, 2);
    g.setTextDatum(TR_DATUM);
    g.setTextColor(C_TEXT);
    g.drawString(value, minus.x - 10, y + 12, 4);

    button(minus, "-", false);
    button(plus,  "+", false);
}

static void draw_settings(const cyd_ui_t *ui)
{
    char b[24];

    snprintf(b, sizeof b, "%u%%", (unsigned)ui->dim_level);
    stepper(CYD_SET_ROW0_Y, "DIM LEVEL", b, CYD_SET_DIM_MINUS, CYD_SET_DIM_PLUS);

    if (ui->dim_timeout_s == 0) snprintf(b, sizeof b, "NEVER");
    else                        snprintf(b, sizeof b, "%us", (unsigned)ui->dim_timeout_s);
    stepper(CYD_SET_ROW1_Y, "DIM AFTER", b, CYD_SET_TMO_MINUS, CYD_SET_TMO_PLUS);

    button(CYD_BTN_LEFT, "BACK", false);
    /* MID, not RIGHT -- RIGHT sits under the hamburger. */
    button(CYD_BTN_MID,  "MORE", false);
    /* SETTINGS is in the hamburger whitelist, so it must DRAW one. It did not,
     * leaving x258..313 live and unpainted -- the same drawn-versus-hit-
     * geometry defect as the strip beside it, in the other direction. */
    hamburger();
}

/* A two-state button. Distinct from button()'s `hot`, which paints C_BAD:
 * red means "this is destructive", and fan boost is neither destructive nor a
 * warning. Green reads as "on" without implying danger. */
static void toggle(cyd_rect_t r, const char *label, bool on)
{
    fill_rect(r, on ? C_OK : C_PANEL);
    g.drawRect(r.x, r.y, r.w, r.h, on ? C_OK : C_ACCENT);
    g.setTextColor(on ? C_BG : C_ACCENT, on ? C_OK : C_PANEL);
    g.setTextDatum(MC_DATUM);
    g.drawString(label, r.x + r.w / 2, r.y + r.h / 2, 2);
}

/* const-correct field read. cyd_ui_field() hands back a writable pointer for
 * the keyboard; drawing has no business with that. */
static const char *field_value(const cyd_ui_t *ui, int i)
{
    switch (i) {
    case CYD_FIELD_HOST:   return ui->pool_host;
    case CYD_FIELD_PORT:   return ui->pool_port;
    case CYD_FIELD_WORKER: return ui->pool_worker;
    case CYD_FIELD_PASS:   return ui->pool_pass;
    /* Missing until now, so the keyboard's value line rendered "" for every
     * keystroke of an SSID or a 63-character WPA passphrase -- blind entry, on
     * an uncalibrated resistive panel, for the one field whose failure mode is
     * taking a headless board off the network. */
    case CYD_FIELD_SSID:   return ui->wifi_ssid;
    case CYD_FIELD_PSK:    return ui->wifi_psk;
    default:               return "";
    }
}

/* Show the TAIL of an over-long value, marked with a leading ellipsis.
 *
 * The tail, not the head: a worker is <wallet>.<name>, the wallets all look
 * alike for their first several characters, and the part that says WHICH rig
 * this is lives at the end. Truncating the head would hide the only bit worth
 * reading. */
static const char *elide(const char *v, char *buf, size_t cap, size_t maxch)
{
    size_t n = strlen(v);
    /* maxch < 3 would underflow (maxch - 2) in size_t arithmetic below and
     * index far outside the string. Both callers pass 26 and 30 today; this is
     * here so the third one cannot be the bug. */
    if (maxch < 3) {
        if (cap) buf[0] = 0;
        return buf;
    }
    if (n <= maxch) {
        snprintf(buf, cap, "%s", v);
        return buf;
    }
    snprintf(buf, cap, "..%s", v + (n - (maxch - 2)));
    return buf;
}

/* ONE label table covering EVERY field, indexed by cyd_field_t.
 *
 * This was POOL_LABELS[CYD_POOL_ROWS] -- four entries -- and the keyboard
 * header indexed it with ui->edit_field, which is CYD_FIELD_SSID (4) or
 * CYD_FIELD_PSK (5) whenever the keyboard was opened from WIFI SETUP. That
 * read a const char * from past the end of the array and handed it to
 * drawString: garbage at best, a LoadProhibited reboot in practice, on the
 * first touch of the SSID row. Sized by CYD_FIELD_COUNT so adding a field
 * without adding its label is a compile error, not a crash. */
static const char *FIELD_LABELS[CYD_FIELD_COUNT] = {
    "HOST", "PORT", "WORKER", "PASS", "SSID", "PSK"
};
static const char *POOL_LABELS[CYD_POOL_ROWS] = { "HOST", "PORT", "WORKER", "PASS" };

/* WIFI SETUP. Two rows sharing the pool editor's keyboard, so the two feel
 * like one mechanism rather than two.
 *
 * The PSK is MASKED. Unlike the pool password -- which is "x" on every stratum
 * pool alive and is not a secret -- a WPA passphrase on a panel bolted to the
 * front of a machine is readable by anyone in the room. */
static void draw_wifi(const cyd_ui_t *ui, const cyd_status_t *st)
{
    static const char *L[CYD_WIFI_ROWS] = { "SSID", "PSK" };
    char masked[CYD_WIFI_PSK_MAX];

    for (int i = 0; i < CYD_WIFI_ROWS; i++) {
        cyd_rect_t r = CYD_WIFI_ROW(i);
        const char *v = (i == 0) ? ui->wifi_ssid : ui->wifi_psk;
        bool empty = (v[0] == 0);
        /* A saved passphrase counts as set for the border too -- a red box
         * around a row that says "(saved)" would contradict itself. */
        bool have = !empty || (i == 1 && st && st->wifi_psk_set);
        fill_rect(r, C_PANEL);
        g.drawRect(r.x, r.y, r.w, r.h, have ? C_ACCENT : C_BAD);

        g.setTextDatum(TL_DATUM);
        g.setTextColor(C_DIM);
        g.drawString(L[i], r.x + 6, r.y + 9, 2);

        uint16_t vc = empty ? C_BAD : C_TEXT;

        if (i == 1 && !empty) {
            size_t n = strlen(v);
            if (n >= sizeof masked) n = sizeof masked - 1;
            for (size_t k = 0; k < n; k++) masked[k] = '*';
            masked[n] = 0;
            v = masked;
        } else if (i == 1 && empty && st && st->wifi_psk_set) {
            /* A PASSPHRASE IS CONFIGURED, it just is not in this buffer.
             *
             * The row used to read "-- tap to set --" here, which is simply
             * untrue after any restart: the board has been connecting with a
             * saved passphrase all along. Dim, because it is the stored value
             * rather than something typed, and unchanged unless it is
             * retyped. */
            v = "******** (saved)";
            vc = C_DIM;
            empty = false;
        }

        g.setTextDatum(TR_DATUM);
        g.setTextColor(vc);
        g.drawString(empty ? "-- tap to set --" : v, r.x + r.w - 6, r.y + 9, 2);
    }

    /* Say the rule rather than let SAVE do nothing. */
    size_t n = strlen(ui->wifi_psk);
    /* Not while showing a SAVED passphrase: the rule applies to what is being
     * typed, and complaining about a length nobody has entered is noise. */
    if (ui->wifi_ssid[0] && !(n == 0 && st && st->wifi_psk_set) &&
        (n < 8 || n > 63)) {
        g.setTextDatum(TL_DATUM);
        g.setTextColor(C_WARN);
        g.drawString("PSK must be 8-63 characters", 10, 126, 2);
    }

    button(CYD_WIFI_BACK, "BACK", false);
    button(CYD_WIFI_SCAN, "SCAN", false);
    button(CYD_WIFI_SAVE, "SAVE", true);
}

/*
 * The scan results.
 *
 * The list is what the MINER can hear, not what the panel can -- see
 * cyd_proto.h. That distinction is the whole reason this screen exists rather
 * than the ESP32 scanning for itself: a network the panel can see and the
 * miner cannot is a network you would pick and then fail to join.
 *
 * SSIDs here came off the air and down a serial link. They are drawn and
 * copied, and nothing else is done with them.
 */
/*
 * Waiting out a reboot or a restart.
 *
 * The elapsed seconds are the point. Without them this is a static message
 * and there is no way to tell "in progress" from "stuck" -- and a reboot that
 * has taken three minutes IS stuck. It clears when STATUS returns, so the
 * screen going away is real evidence the miner is back rather than a timer
 * expiring and hoping.
 */
static void draw_busy(const cyd_ui_t *ui, uint32_t now_ms)
{
    char b[48];
    uint32_t secs = ui->busy_since_ms ? (now_ms - ui->busy_since_ms) / 1000u : 0;

    g.setTextDatum(MC_DATUM);
    g.setTextColor(C_ACCENT);
    g.drawString(ui->busy_what ? ui->busy_what : "WORKING", CYD_LAYOUT_W / 2, 96, 4);

    g.setTextColor(C_DIM);
    g.drawString("waiting for the miner to come back",
                 CYD_LAYOUT_W / 2, 124, 2);

    snprintf(b, sizeof b, "%us", (unsigned)secs);
    g.setTextColor(secs > 120 ? C_WARN : C_TEXT);
    g.drawString(b, CYD_LAYOUT_W / 2, 152, 4);

    if (secs > 120) {
        /* Long enough that something has probably gone wrong, and saying so
         * beats a spinner that never stops. */
        g.setTextColor(C_WARN);
        g.drawString("taking longer than expected",
                     CYD_LAYOUT_W / 2, 180, 2);
    }
    g.setTextDatum(TL_DATUM);
}

static void draw_wifi_list(const cyd_ui_t *ui)
{
    char b[64];

    if (ui->scan_busy) {
        g.setTextDatum(MC_DATUM);
        g.setTextColor(C_DIM);
        g.drawString("scanning...", CYD_LAYOUT_W / 2, 100, 4);
        g.setTextDatum(TL_DATUM);
    } else if (ui->scan_n == 0) {
        /* An empty result is a RESULT, and saying so is the point -- the
         * alternative is a blank screen that looks like a hang. */
        g.setTextDatum(MC_DATUM);
        g.setTextColor(C_WARN);
        g.drawString("no networks found", CYD_LAYOUT_W / 2, 100, 4);
        g.setTextColor(C_DIM);
        g.drawString("is the antenna connected?", CYD_LAYOUT_W / 2, 128, 2);
        g.setTextDatum(TL_DATUM);
    } else {
        for (int i = 0; i < CYD_WL_ROWS && i < ui->scan_n; i++) {
            cyd_rect_t r = CYD_WL_ROW(i);
            fill_rect(r, C_PANEL);
            g.drawRect(r.x, r.y, r.w, r.h, C_ACCENT);

            g.setTextDatum(TL_DATUM);
            g.setTextColor(C_TEXT);
            g.drawString(elide(ui->scan_ssid[i], b, sizeof b, 28),
                         r.x + 6, r.y + 4, 2);

            /* Signal as dBm. Colour-coded on the thresholds that matter for
             * whether an association will actually hold: better than -60 is
             * comfortable, worse than -75 is marginal. */
            snprintf(b, sizeof b, "%d", ui->scan_rssi[i]);
            g.setTextDatum(TR_DATUM);
            g.setTextColor(ui->scan_rssi[i] > -60 ? C_OK
                         : ui->scan_rssi[i] > -75 ? C_WARN : C_BAD);
            g.drawString(b, r.x + r.w - 6, r.y + 4, 2);
            g.setTextDatum(TL_DATUM);
        }
    }

    button(CYD_WL_BACK,  "BACK",  false);
    button(CYD_WL_AGAIN, "AGAIN", false);
}

static void draw_pool(const cyd_ui_t *ui)
{
    char b[80];
    for (int i = 0; i < CYD_POOL_ROWS; i++) {
        cyd_rect_t r = CYD_POOL_ROW(i);
        bool empty = (field_value(ui, i)[0] == 0);
        fill_rect(r, C_PANEL);
        /* An empty required field is outlined in red: SAVE refuses to send an
         * incomplete pool, and a SAVE that silently does nothing is the worst
         * possible feedback. */
        g.drawRect(r.x, r.y, r.w, r.h, empty ? C_BAD : C_ACCENT);

        g.setTextDatum(TL_DATUM);
        g.setTextColor(C_DIM);
        g.drawString(POOL_LABELS[i], r.x + 6, r.y + 9, 2);

        g.setTextDatum(TR_DATUM);
        g.setTextColor(empty ? C_BAD : C_TEXT);
        g.drawString(empty ? "-- tap to set --"
                             : elide(field_value(ui, i), b, sizeof b, 26),
                       r.x + r.w - 6, r.y + 9, 2);
    }

    button(CYD_POOL_BACK, "BACK", false);
    button(CYD_POOL_SAVE, "SAVE", true);
}

/*
 * Which character is under x, in field coordinates.
 *
 * Measured with the SAME font and the SAME visible window the field is drawn
 * with -- anything else lands the caret somewhere the user did not point.
 * That is also why this cannot live in cyd_ui.c: font 2 is proportional, and
 * an average-width guess is worst on the long strings (wallet addresses) that
 * tapping-to-position exists to help with.
 *
 * Returns an index into the WHOLE value, not the window. Tapping past the end
 * of the text puts the cursor at the end, which is what every text field does.
 */
size_t cyd_ui_kb_index_at(const cyd_ui_t *ui, int x)
{
    if (!ui)
        return 0;

    const char *v = field_value(ui, ui->edit_field);
    char secret[CYD_POOL_WORKER_MAX];
    if (cyd_ui_field_is_secret(ui->edit_field) && !ui->kb_reveal) {
        size_t n = strlen(v);
        if (n >= sizeof secret) n = sizeof secret - 1;
        for (size_t k = 0; k < n; k++) secret[k] = '*';
        secret[n] = 0;
        v = secret;
    }

    size_t vlen  = strlen(v);
    size_t start = ui->kb_view > vlen ? vlen : ui->kb_view;
    size_t avail = vlen - start;
    size_t vis   = cyd_ui_kb_visible(ui->edit_field);
    size_t shown = avail < vis ? avail : vis;

    int x0 = CYD_KB_FIELD.x + 5;
    if (x <= x0)
        return start;

    /* Walk the window, stopping at the character whose MIDPOINT the tap is
     * past -- so tapping the left half of a glyph puts the caret before it and
     * the right half after it, which is what a text field does. */
    char pre[80];
    for (size_t i = 0; i < shown; i++) {
        snprintf(pre, sizeof pre, "%.*s", (int)(i + 1), v + start);
        int w_next = x0 + tft.textWidth(pre, 2);
        snprintf(pre, sizeof pre, "%.*s", (int)i, v + start);
        int w_this = x0 + tft.textWidth(pre, 2);
        if (x < (w_this + w_next) / 2)
            return start + i;
    }
    return start + shown;
}

static void draw_keyboard(const cyd_ui_t *ui)
{
    char b[80];

    /* THE FIELD. A bordered row of its own -- the value used to be printed at
     * y=26, inside the header band, so it looked like part of the title
     * rather than like something being edited. The header already names the
     * field (main.cpp passes it as the screen title), so this row carries
     * only the value and the caret. */
    {
        cyd_rect_t f = CYD_KB_FIELD;
        fill_rect(f, C_PANEL);
        g.drawRect(f.x, f.y, f.w, f.h, C_ACCENT);

        const char *v = field_value(ui, ui->edit_field);

        /* PASSWORDS ARE MASKED WHILE BEING TYPED.
         *
         * This screen is the only place a passphrase is ever visible at all --
         * a SAVED one is never sent to the panel, so the reveal toggle cannot
         * expose anything but what is being entered right now. Off by default
         * and reset every time the keyboard opens, so it cannot be left on. */
        char secret[CYD_POOL_WORKER_MAX];
        bool is_secret = cyd_ui_field_is_secret(ui->edit_field);
        if (is_secret && !ui->kb_reveal) {
            size_t n = strlen(v);
            if (n >= sizeof secret) n = sizeof secret - 1;
            for (size_t k = 0; k < n; k++) secret[k] = '*';
            secret[n] = 0;
            v = secret;
        }

        /* A WINDOW THAT FOLLOWS THE CURSOR, not a fixed view of the tail.
         *
         * The worker is a wallet plus a name -- about 40 characters against a
         * field showing 30 -- so a view pinned to the end meant moving the
         * cursor left took it somewhere off screen with nothing to show where
         * it had gone. cyd_ui_kb_follow() owns where the window sits; this
         * only renders it.
         *
         * The arrows say there is more text in that direction, so a truncated
         * value never looks like the whole value. */
        size_t vlen  = strlen(v);
        size_t start = ui->kb_view;
        if (start > vlen)
            start = vlen;
        size_t avail = vlen - start;
        size_t vis     = cyd_ui_kb_visible(ui->edit_field);
        size_t shown_n = avail < vis ? avail : vis;

        snprintf(b, sizeof b, "%.*s", (int)shown_n, v + start);

        g.setTextDatum(TL_DATUM);
        g.setTextColor(C_TEXT);
        g.drawString(b, f.x + 5, f.y + 2, 2);

        if (start > 0) {
            g.setTextColor(C_ACCENT);
            g.drawString("<", f.x - 3, f.y + 2, 1);
        }
        if (start + shown_n < vlen) {
            g.setTextColor(C_ACCENT);
            g.drawString(">", f.x + f.w - 6, f.y + 2, 1);
        }

        /* The caret, at the insertion point. Solid rather than blinking: a
         * blink needs a timer in a screen model that deliberately has no
         * clock, and a steady bar answers the question just as well. */
        /* AT THE CURSOR, measured against the text ACTUALLY DRAWN -- the
         * window may start part way into the value, so the offset has to be
         * relative to it, not to the whole string. */
        size_t vis_cur = (ui->kb_cursor > start) ? ui->kb_cursor - start : 0;
        if (vis_cur > shown_n)
            vis_cur = shown_n;
        char pre[80];
        snprintf(pre, sizeof pre, "%.*s", (int)vis_cur, b);
        int cx = f.x + 5 + g.textWidth(pre, 2) + 1;
        if (cx > f.x + f.w - 4)
            cx = f.x + f.w - 4;
        g.fillRect(cx, f.y + 3, 2, f.h - 6, C_ACCENT);

        /* SHOW/HIDE, only on a field that is actually a secret -- on a
         * hostname it would be a button that does nothing visible. */
        if (is_secret) {
            cyd_rect_t e = CYD_KB_EYE;
            fill_rect(e, ui->kb_reveal ? C_ACCENT : C_PANEL);
            g.drawRect(e.x, e.y, e.w, e.h, C_ACCENT);
            g.setTextDatum(MC_DATUM);
            g.setTextColor(ui->kb_reveal ? C_BG : C_ACCENT);
            g.drawString(ui->kb_reveal ? "HIDE" : "SHOW",
                         e.x + e.w / 2, e.y + e.h / 2, 1);
            g.setTextDatum(TL_DATUM);
        }
    }

    for (int r = 0; r < CYD_KB_ROWS; r++) {
        for (int c = 0; c < CYD_KB_COLS; c++) {
            char ch = cyd_ui_kb_char(c, r, ui->kb_shift);
            if (!ch)
                continue;
            cyd_rect_t k = CYD_KB_KEY(c, r);
            char lbl[2] = { ch, 0 };
            fill_rect(k, C_PANEL);
            g.drawRect(k.x, k.y, k.w, k.h, C_ACCENT);
            g.setTextDatum(MC_DATUM);
            g.setTextColor(C_TEXT);
            g.drawString(lbl, k.x + k.w / 2, k.y + k.h / 2, 2);
        }
    }

    /* Three characters maximum -- the buttons are 37px and "CANCEL" is about
     * 48px at this font, which is exactly why it used to overflow. */
    toggle(CYD_KB_SHIFT,  "SH",  ui->kb_shift);
    button(CYD_KB_LEFT,   "<",   false);
    button(CYD_KB_RIGHT,  ">",   false);
    button(CYD_KB_BKSP,   "BS",  false);   /* deletes backwards */
    button(CYD_KB_FWDDEL, "DEL", false);   /* deletes forwards  */
    button(CYD_KB_CLEAR,  "CLR", false);
    button(CYD_KB_CANCEL, "ESC", false);
    button(CYD_KB_OK,     "OK",  true);
}

static void draw_actions(const cyd_ui_t *ui)
{
    g.setTextDatum(TL_DATUM);
    g.setTextColor(C_DIM);
    g.drawString("RESET and REBOOT ask for confirmation.", 10, 58, 2);
    g.drawString("Fan boost is immediate and reversible.", 10, 76, 2);

    toggle(CYD_ACT_FAN, ui->fan_boost ? "FAN: BOOST" : "FAN: AUTO",
           ui->fan_boost);
    button(CYD_ACT_POOL, "EDIT POOL", false);

    button(CYD_BTN_LEFT,  "BACK",   false);
    button(CYD_BTN_MID,   "RESET",  false);
    button(CYD_BTN_RIGHT, "REBOOT", true);
}

static void draw_confirm(const cyd_ui_t *ui)
{
    const char *what = "RESET STATISTICS?";
    const char *note = "Share counters return to zero.";
    if (ui->pending == CYD_ACTION_REBOOT) {
        what = "REBOOT THE MINER?";
        note = "Mining stops until it comes back.";
    } else if (ui->pending == CYD_ACTION_RESTART) {
        what = "RESTART THE MINER?";
        note = "Hashing stops for a few seconds.";
    } else if (ui->pending == CYD_ACTION_SET_WIFI) {
        what = "CHANGE WIFI?";
        /* Worth spelling out: this is how a headless board gets lost. */
        note = "Wrong details take the board offline.";
    } else if (ui->pending == CYD_ACTION_SET_POOL) {
        what = "CHANGE THE POOL?";
        /* Say that it persists. This rewrites /boot/am01-miner.conf,
         * so it is not a runtime tweak that a restart undoes. */
        note = "Saved to /boot; survives a reflash.";
    }

    g.setTextDatum(MC_DATUM);
    g.setTextColor(C_BAD);
    g.drawString(what, CYD_LAYOUT_W / 2, 70, 4);
    g.setTextColor(C_DIM);
    g.drawString(note, CYD_LAYOUT_W / 2, 104, 2);

    /* NO is the wide left button and YES the narrow right one -- the easy
     * target is the harmless one. Checked by test_cyd_ui.c, which asserts
     * YES is no larger than NO. */
    button(CYD_CONFIRM_NO,  "NO",  false);
    button(CYD_CONFIRM_YES, "YES", true);
}

/* ---- entry point ------------------------------------------------------ */

/*
 * The update screen.
 *
 * Worth the code: an OTA takes about a minute, and for that minute the panel
 * would otherwise sit showing a frozen hashrate while the miner appears to
 * have stopped talking to it. Someone WILL pull the power on that. Saying
 * "UPDATING 43%" is the difference between a quiet minute and a bricked
 * panel -- and the one thing that must not happen during a flash write is a
 * power cut.
 *
 * Drawn incrementally: only the bar and the number change, so this cannot
 * become the thing that slows the transfer down.
 */
void cyd_ui_draw_ota(int pct, const char *err)
{
    /* Straight to the display, not through a band. This screen is static
     * apart from one number and one bar, it is redrawn incrementally, and it
     * has to keep working while the flash is being rewritten -- the simplest
     * path is the right one here. */
    Gfx saved = g;
    g.t = &tft;
    g.yoff = 0;

    static int  last_pct = -1;
    static bool framed;

    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;

    if (!framed) {
        framed = true;
        last_pct = -1;
        g.fillScreen(C_BG);

        g.setTextDatum(MC_DATUM);
        g.setTextColor(C_TEXT, C_BG);
        g.drawString("UPDATING PANEL", 160, 78, 4);

        g.setTextColor(C_DIM, C_BG);
        g.drawString("do not remove power", 160, 108, 2);

        g.drawRect(40, 130, 240, 26, C_DIM);
    }

    if (err && *err) {
        g.setTextDatum(MC_DATUM);
        g.setTextColor(C_BAD, C_BG);
        g.drawString("UPDATE FAILED", 160, 180, 4);
        g.setTextColor(C_DIM, C_BG);
        g.drawString(err, 160, 205, 2);
        framed = false;          /* next call repaints from scratch */
        g = saved;
        return;
    }

    if (pct != last_pct) {
        last_pct = pct;
        int w = (236 * pct) / 100;
        g.fillRect(42, 132, w, 22, C_ACCENT);
        if (w < 236)
            g.fillRect(42 + w, 132, 236 - w, 22, C_PANEL);

        char buf[8];
        snprintf(buf, sizeof buf, "%d%%", pct);
        g.setTextDatum(MC_DATUM);
        /* CLEARED FIRST, AND DRAWN OPAQUE.
         *
         * This screen is the one place transparent text is wrong. Everything
         * else composes a whole frame off-screen from a fresh background, so
         * there is never anything stale underneath -- but this draws STRAIGHT
         * TO THE GLASS and updates in place, so a transparent "100%" lands on
         * top of the "99%" already there. The percentages piled up into a
         * white smear.
         *
         * The rect is cleared as well as the text being opaque, because the
         * datum is centred: "100%" is wider than "9%", so shrinking back
         * would leave the ends of the longer string behind. */
        g.fillRect(118, 163, 84, 30, C_BG);
        g.setTextColor(C_TEXT, C_BG);
        g.drawString(buf, 160, 178, 4);
    }

    g = saved;
}

static void draw_screen(cyd_ui_t *ui, const cyd_status_t *st)
{

    switch (ui->screen) {
    case CYD_SCREEN_GLANCE:
        header("", st, ui->link_down);
        draw_glance(st, ui->link_down);
        break;
    case CYD_SCREEN_DETAIL:
        header("DETAIL", st, ui->link_down);
        /* The MINER'S wall clock, passed through: a CYD has no RTC and NTP
         * may never have run.
         *
         * `updated`, NOT `epoch + uptime`. That was the first attempt and it
         * is nonsense -- `epoch` is when the current OdoCrypt epoch began,
         * not when the miner started, so the sum is an arbitrary instant. On
         * a real status it rendered "9d 16h" against a true "2d 7h", which is
         * exactly the sort of wrong that looks right. */
        draw_detail(st, st->updated);
        break;
    case CYD_SCREEN_SETTINGS:
        header("SETTINGS", st, ui->link_down);
        draw_settings(ui);
        break;
    case CYD_SCREEN_ACTIONS:
        header("ACTIONS", st, ui->link_down);
        draw_actions(ui);
        break;
    case CYD_SCREEN_MENU:
        header("", st, ui->link_down);
        draw_menu();
        break;
    case CYD_SCREEN_WIFI:
        header("WIFI SETUP", st, ui->link_down);
        draw_wifi(ui, st);
        break;
    case CYD_SCREEN_WIFI_LIST:
        header("PICK NETWORK", st, ui->link_down);
        draw_wifi_list(ui);
        break;
    case CYD_SCREEN_BUSY:
        header("PLEASE WAIT", st, ui->link_down);
        draw_busy(ui, ui->busy_now_ms);
        break;
    case CYD_SCREEN_POOL:
        header("POOL", st, ui->link_down);
        draw_pool(ui);
        break;
    case CYD_SCREEN_KEYBOARD:
        header(FIELD_LABELS[ui->edit_field], st, ui->link_down);
        draw_keyboard(ui);
        break;
    case CYD_SCREEN_CONFIRM:
        header("CONFIRM", st, ui->link_down);
        draw_confirm(ui);
        break;
    default:
        break;
    }

    /* MINER DOWN, over everything. Deliberately not a subtle indicator: a
     * stale reading presented as live is worse than an honest "no data",
     * because it is how someone concludes the miner is fine while it is
     * down. The numbers stay visible underneath -- they were true once, and
     * the last known state is useful -- but they are unmistakably stale. */
    /* GLANCE and DETAIL ONLY.
     *
     * The banner is a full-width bar across the middle and touch geometry does
     * not move under it, so on every other screen it sat on top of live
     * controls: on MENU it covered WIFI SETUP entirely (CYD_AS_ROW(3) is
     * y107..133) and clipped RESTART, so tapping the red bar FIRED one of
     * them; on ACTIONS it buried most of both toggles, and fan boost returns
     * without a confirm; on KEYBOARD it covered two character rows. link_down
     * is precisely when someone reaches for RESTART or REBOOT.
     *
     * Nothing is lost by scoping it -- the header pill already reads MINER
     * DOWN on every screen. */
    if (ui->link_down && (ui->screen == CYD_SCREEN_GLANCE ||
                          ui->screen == CYD_SCREEN_DETAIL)) {
        int by = CYD_LAYOUT_H / 2 - 18;
        g.fillRect(0, by, CYD_LAYOUT_W, 36, C_BAD);
        g.setTextDatum(MC_DATUM);
        g.setTextColor(C_TEXT);
        g.drawString("MINER DOWN", CYD_LAYOUT_W / 2, by + 18, 4);
    }
}

/*
 * One frame: for each band, lay down that slice of the honeycomb, draw the
 * whole screen into it (the sprite clips what falls outside), and push.
 *
 * Two SPI writes per frame rather than one. They are milliseconds apart and
 * each is atomic, so there is no state in which the panel shows a cleared
 * region -- which is the thing that was being seen as a blink.
 */
void cyd_ui_draw(cyd_ui_t *ui, const cyd_status_t *st)
{
    if (!ui || !st)
        return;

    if (!band_ok) {
        /* No sprite: draw once, straight to the glass, exactly as before. */
        g.yoff = 0;
        hexbg();
        draw_screen(ui, st);
        return;
    }

    for (int by = 0; by < CYD_LAYOUT_H; by += BAND_H) {
        int bh = CYD_LAYOUT_H - by;
        if (bh > BAND_H) bh = BAND_H;

        band.setSwapBytes(true);
        for (int r = 0; r < bh; r++)
            band.pushImage(0, r, CYD_BG_W, 1,
                           (uint16_t *)(const uint16_t *)
                               &CYD_BG[(size_t)(by + r) * CYD_BG_W]);
        band.setSwapBytes(false);

        g.yoff = by;
        draw_screen(ui, st);
        band.pushSprite(0, by);
    }
    g.yoff = 0;
}
