/*
 * cyd_ui_draw.cpp -- the drawing half of the panel UI.
 *
 * PAIRED WITH cyd_ui.c, which owns the screen model and touch handling and
 * contains no drawing at all. That split is what lets the whole navigation
 * model -- including the confirm guards -- run on a PC in milliseconds
 * (sim/test_cyd_ui.c, 41 checks). Nothing in this file is testable off
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
 * Values are formatted by cyd_fmt_* (29 checks), never inline. Those
 * functions are where "-1" becomes "--" rather than a fault the board does
 * not have.
 */

#include <Arduino.h>
#include <SPI.h>
#include <TFT_eSPI.h>
#include <XPT2046_Touchscreen.h>

#include <string.h>
#include <math.h>
#include <string.h>
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
    tft.fillRect(r.x, r.y, r.w, r.h, c);
}

/* A button, drawn into its LAYOUT rect. `hot` marks the destructive one. */
static void button(cyd_rect_t r, const char *label, bool hot)
{
    fill_rect(r, hot ? C_BAD : C_PANEL);
    tft.drawRect(r.x, r.y, r.w, r.h, hot ? C_BAD : C_ACCENT);
    tft.setTextColor(hot ? C_TEXT : C_ACCENT, hot ? C_BAD : C_PANEL);
    tft.setTextDatum(MC_DATUM);
    tft.drawString(label, r.x + r.w / 2, r.y + r.h / 2, 2);
}

/* label on the left, value right-aligned -- a two-column row. */
static void row(int y, const char *label, const char *value, uint16_t vc)
{
    tft.setTextDatum(TL_DATUM);
    tft.setTextColor(C_DIM, C_BG);
    tft.drawString(label, 10, y, 2);
    tft.setTextDatum(TR_DATUM);
    tft.setTextColor(vc, C_BG);
    tft.drawString(value, CYD_LAYOUT_W - 10, y, 2);
}

/* The mark from the dashboard's SVG: a hexagon outline with a smaller filled
 * hexagon inside it. Drawn rather than embedded -- it is six points. */
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
            tft.fillRect(x + c * scale, y + r * scale, scale, scale, C_ACCENT);
        }
}

/* THE HONEYCOMB. odo_ui.c blits a bg.png; drawing the hex grid costs ~150KB
 * less flash and is the same picture. Faint on purpose -- it is texture behind
 * data. The previous version of this panel skipped it entirely, which is most
 * of why the two screens did not look like the same product.
 *
 * Flat-top hexagons on the usual offset grid: columns step 1.5*R and odd
 * columns drop half a row. */
static void hexbg(void)
{
    const int R  = 17;                    /* circumradius */
    const int dx = (R * 3) / 2;
    const int dy = (int)(R * 1.732f);
    for (int col = -1; col * dx < CYD_LAYOUT_W + R; col++) {
        int cx   = col * dx;
        int yoff = (col & 1) ? dy / 2 : 0;
        for (int row = -1; row * dy + yoff < CYD_LAYOUT_H + R; row++) {
            int cy = row * dy + yoff;
            int px = 0, py = 0;
            for (int k = 0; k <= 6; k++) {
                float a = (float)k * 1.0471976f;   /* 60 degrees */
                int nx = cx + (int)(R * cosf(a));
                int ny = cy + (int)(R * sinf(a));
                if (k)
                    tft.drawLine(px, py, nx, ny, C_HEX);
                px = nx; py = ny;
            }
        }
    }
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
    tft.setTextDatum(TR_DATUM);
    tft.setTextColor(C_DIM, C_PANEL);
    tft.drawString(b, CYD_LAYOUT_W - 76, 4, 2);
}

/* ONE hamburger, bottom right, where odo_ui.c puts it. */
static void hamburger(void)
{
    cyd_rect_t r = CYD_MENU_BTN;
    tft.drawRect(r.x, r.y, r.w, r.h, C_ACCENT);
    for (int i = 0; i < 3; i++)
        tft.fillRect(r.x + 12, r.y + 9 + i * 6, r.w - 24, 3, C_ACCENT);
}

static const char *AS_LABELS[CYD_AS_N] = {
    "GLANCE", "DETAIL", "SETUP", "WIFI SETUP", "RESTART", "REBOOT", "CANCEL"
};

/* WIFI SETUP and RESTART are drawn but INERT, and drawn dim so that is
 * visible. Both need a protocol verb this link does not have -- cyd_proto.h
 * carries fan_boost, reset_stats, reboot and set_pool, and nothing for WiFi
 * credentials or for restarting the daemon. Greyed is honest; hiding them
 * would make this a different panel again, and showing them live would be a
 * button that silently does nothing. */
static bool as_enabled(int i)
{
    return !(i == 3 || i == 4);
}

static void draw_menu(void)
{
    cyd_rect_t top = CYD_AS_ROW(0), bot = CYD_AS_ROW(CYD_AS_N - 1);
    int pad = 12;
    tft.fillRect(top.x - pad, top.y - pad, top.w + 2 * pad,
                 (bot.y + bot.h - top.y) + 2 * pad, C_ACCENT);
    tft.fillRect(top.x - pad + 1, top.y - pad + 1, top.w + 2 * pad - 2,
                 (bot.y + bot.h - top.y) + 2 * pad - 2, C_BG);

    for (int i = 0; i < CYD_AS_N; i++) {
        cyd_rect_t r = CYD_AS_ROW(i);
        uint16_t border = (i == 5) ? C_BAD : (i == 6) ? C_PANEL : C_ACCENT;
        uint16_t tc     = (i == 5) ? C_BAD : (i == 6) ? C_TEXT  : C_ACCENT;
        if (!as_enabled(i)) { border = C_PANEL; tc = C_DIM; }
        tft.fillRect(r.x, r.y, r.w, r.h, border);
        tft.fillRect(r.x + 1, r.y + 1, r.w - 2, r.h - 2, C_PANEL);
        tft.setTextDatum(MC_DATUM);
        tft.setTextColor(tc, C_PANEL);
        tft.drawString(AS_LABELS[i], r.x + r.w / 2, r.y + r.h / 2, 2);
    }
}

static void header(const char *title, const cyd_status_t *st, bool link_down)
{
    tft.fillRect(0, 0, CYD_LAYOUT_W, 36, C_PANEL);
    tft.fillRect(0, 36, CYD_LAYOUT_W, 2, C_ACCENT);

    logo(4, 2, 2);

    tft.setTextDatum(TL_DATUM);
    tft.setTextColor(C_TEXT, C_PANEL);
    tft.drawString("ODO MINER", 40, 8, 4);
    draw_clock(st->updated);

    const char *tag;
    uint16_t    tc;
    if (link_down)           { tag = "MINER DOWN"; tc = C_BAD;  }
    else if (!st->connected) { tag = "OFFLINE";    tc = C_WARN; }
    else                     { tag = "POOL OK";    tc = C_OK;   }
    tft.setTextDatum(TR_DATUM);
    tft.setTextColor(tc, C_PANEL);
    tft.drawString(tag, CYD_LAYOUT_W - 8, 14, 2);

    /* The screen's own name, only when it is not GLANCE -- odo_ui.c's glance
     * header carries the brand alone. */
    if (title && title[0]) {
        tft.setTextDatum(TR_DATUM);
        tft.setTextColor(C_DIM, C_PANEL);
        tft.drawString(title, CYD_LAYOUT_W - 8, 2, 2);
    }
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

    /* hashrate hero */
    tft.setTextDatum(TL_DATUM);
    tft.setTextColor(C_DIM, C_BG);
    tft.drawString("HASHRATE", 14, 42, 2);

    cyd_fmt_hashrate(st->hashrate, b, (int)sizeof b);
    {
        /* Split "82.51 MH/s" so the number can use the big font. */
        char num[24], *sp = strchr(b, ' ');
        const char *unit = "";
        size_t n = sp ? (size_t)(sp - b) : strlen(b);
        if (n >= sizeof num) n = sizeof num - 1;
        memcpy(num, b, n); num[n] = 0;
        if (sp) unit = sp + 1;
        tft.setTextColor(C_TEXT, C_BG);
        tft.drawString(num, 14, 54, 6);
        int w = tft.textWidth(num, 6);
        tft.setTextColor(C_ACCENT, C_BG);
        tft.drawString(unit, 14 + w + 6, 76, 4);
    }

    /* shapechange countdown + progress bar */
    tft.setTextColor(C_DIM, C_BG);
    tft.drawString("SHAPECHANGE IN", 14, 110, 2);

    int bar_full = CYD_LAYOUT_W - 28;
    if (st->epoch && st->epoch_next > st->epoch) {
        long left = (long)st->epoch_next - (long)st->updated;
        if (left < 0) left = 0;
        snprintf(b, sizeof b, "%ldd %ldh %ldm",
                 left / 86400, (left % 86400) / 3600, (left % 3600) / 60);
        tft.setTextColor(C_TEXT, C_BG);
        tft.drawString(b, 14, 122, 4);

        long total = (long)st->epoch_next - (long)st->epoch;
        long done  = (long)st->updated - (long)st->epoch;
        if (done < 0) done = 0;
        int fill = (total > 0) ? (int)((long)bar_full * done / total) : 0;
        if (fill > bar_full) fill = bar_full;
        tft.fillRect(14, 148, bar_full, 7, C_PANEL);
        if (fill > 0) tft.fillRect(14, 148, fill, 7, C_ACCENT);
    } else {
        tft.setTextColor(C_DIM, C_BG);
        tft.drawString("loading...", 14, 122, 2);
        tft.fillRect(14, 148, bar_full, 7, C_PANEL);
    }

    /* Either the wrong-epoch warning, or the compact summary. Never both:
     * odo_ui.c gives the warning the whole strip because nothing else on the
     * screen matters while every share is being rejected. */
    if (st->bitstream_epoch && st->epoch && st->bitstream_epoch != st->epoch) {
        tft.fillRect(6, 158, CYD_LAYOUT_W - 12, 18, C_BAD);
        tft.setTextDatum(MC_DATUM);
        tft.setTextColor(C_TEXT, C_BAD);
        tft.drawString("! WRONG EPOCH - REBOOT !", CYD_LAYOUT_W / 2, 167, 2);
        tft.setTextDatum(TL_DATUM);
        return;
    }

    /* Line 1: accepted shares, best difficulty this session. */
    tft.setTextColor(C_DIM, C_BG);
    tft.drawString("SHARES", 14, 160, 2);
    snprintf(b, sizeof b, "%llu", (unsigned long long)st->shares_accepted);
    tft.setTextColor(C_TEXT, C_BG);
    tft.drawString(b, 68, 160, 2);

    tft.setTextColor(C_DIM, C_BG);
    tft.drawString("BEST-S", 168, 160, 2);
    /* odo_ui.c has fmt_diff(); this tree formats plainly, as its
     * DETAIL screen already did. */
    snprintf(b, sizeof b, "%.3f", st->best_diff_session);
    tft.setTextColor(C_ACCENT, C_BG);
    tft.drawString(b, 222, 160, 2);

    /* Line 2: temp, accept rate, fan -- with odo_ui.c's own thresholds. */
    unsigned long long total = st->shares_accepted + st->shares_rejected;
    if (st->temp_c >= -50 && st->temp_c <= 150) {
        snprintf(b, sizeof b, "%dC", st->temp_c);
        tft.setTextColor(C_DIM, C_BG);
        tft.drawString("TEMP", 14, 176, 2);
        tft.setTextColor(st->temp_c >= 65 ? C_WARN : C_TEXT, C_BG);
        tft.drawString(b, 54, 176, 2);
    }
    if (total > 0) {
        int pct = (int)(st->shares_accepted * 100ULL / total);
        snprintf(b, sizeof b, "%d%%", pct);
        tft.setTextColor(C_DIM, C_BG);
        tft.drawString("ACC", 120, 176, 2);
        tft.setTextColor(pct >= 90 ? C_OK : pct >= 70 ? C_WARN : C_BAD, C_BG);
        tft.drawString(b, 150, 176, 2);
    }
    if (st->fan_rpm >= 0) {
        snprintf(b, sizeof b, "%d%%", st->fan_duty_pct);
        tft.setTextColor(C_DIM, C_BG);
        tft.drawString("FAN", 220, 176, 2);
        tft.setTextColor(st->fan_duty_pct > 0 ? C_OK : C_DIM, C_BG);
        tft.drawString(b, 250, 176, 2);
    }

    hamburger();
}

static void draw_detail(const cyd_status_t *st, uint32_t now)
{
    char b[48];
    int y = 34;

    cyd_fmt_epoch_left_at(st->epoch_next, now, b, sizeof b);
    /* STALE is the loudest thing this screen can say, and it earns it: past
     * the rollover an un-rebuilt bitstream mines nothing but rejects, and
     * nothing else on the panel would explain why. */
    bool stale = (st->bitstream_epoch != 0 && st->epoch != 0 &&
                  st->bitstream_epoch != st->epoch);
    row(y, "EPOCH IN", stale ? "STALE" : b, stale ? C_BAD : C_TEXT); y += 20;

    row(y, "JOB", st->job_id[0] ? st->job_id : "--", C_TEXT);        y += 20;

    snprintf(b, sizeof b, "%.3f", st->best_diff_session);
    row(y, "BEST (RUN)", b, C_TEXT);                                 y += 20;
    snprintf(b, sizeof b, "%.3f", st->best_diff_alltime);
    row(y, "BEST (ALL)", b, C_TEXT);                                 y += 20;

    snprintf(b, sizeof b, "%llu", (unsigned long long)st->blocks_found);
    row(y, "BLOCKS", b, st->blocks_found ? C_OK : C_DIM);            y += 20;

    snprintf(b, sizeof b, "%s / %s",
             st->backend[0] ? st->backend : "--",
             st->core[0]    ? st->core    : "--");
    row(y, "BACKEND", b, C_DIM);                                     y += 20;

    uint32_t up = st->uptime;
    snprintf(b, sizeof b, "%ud %uh %um",
             up / 86400u, (up % 86400u) / 3600u, (up % 3600u) / 60u);
    row(y, "UPTIME", b, C_DIM);

    button(CYD_BTN_LEFT,  "BACK",    false);
    button(CYD_BTN_MID,   "SET",     false);
    button(CYD_BTN_RIGHT, "ACTIONS", false);
}

static void stepper(int y, const char *label, const char *value,
                    cyd_rect_t minus, cyd_rect_t plus)
{
    tft.setTextDatum(TL_DATUM);
    tft.setTextColor(C_DIM, C_BG);
    tft.drawString(label, 10, y + 12, 2);
    tft.setTextDatum(TR_DATUM);
    tft.setTextColor(C_TEXT, C_BG);
    tft.drawString(value, minus.x - 10, y + 12, 4);

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
}

/* A two-state button. Distinct from button()'s `hot`, which paints C_BAD:
 * red means "this is destructive", and fan boost is neither destructive nor a
 * warning. Green reads as "on" without implying danger. */
static void toggle(cyd_rect_t r, const char *label, bool on)
{
    fill_rect(r, on ? C_OK : C_PANEL);
    tft.drawRect(r.x, r.y, r.w, r.h, on ? C_OK : C_ACCENT);
    tft.setTextColor(on ? C_BG : C_ACCENT, on ? C_OK : C_PANEL);
    tft.setTextDatum(MC_DATUM);
    tft.drawString(label, r.x + r.w / 2, r.y + r.h / 2, 2);
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
    if (n <= maxch) {
        snprintf(buf, cap, "%s", v);
        return buf;
    }
    snprintf(buf, cap, "..%s", v + (n - (maxch - 2)));
    return buf;
}

static const char *POOL_LABELS[CYD_POOL_ROWS] = { "HOST", "PORT", "WORKER", "PASS" };

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
        tft.drawRect(r.x, r.y, r.w, r.h, empty ? C_BAD : C_ACCENT);

        tft.setTextDatum(TL_DATUM);
        tft.setTextColor(C_DIM, C_PANEL);
        tft.drawString(POOL_LABELS[i], r.x + 6, r.y + 9, 2);

        tft.setTextDatum(TR_DATUM);
        tft.setTextColor(empty ? C_BAD : C_TEXT, C_PANEL);
        tft.drawString(empty ? "-- tap to set --"
                             : elide(field_value(ui, i), b, sizeof b, 26),
                       r.x + r.w - 6, r.y + 9, 2);
    }

    button(CYD_POOL_BACK, "BACK", false);
    button(CYD_POOL_SAVE, "SAVE", true);
}

static void draw_keyboard(const cyd_ui_t *ui)
{
    char b[80];

    /* The field being edited and its value so far, at the top where a text
     * cursor would be. */
    tft.setTextDatum(TL_DATUM);
    tft.setTextColor(C_DIM, C_BG);
    tft.drawString(POOL_LABELS[ui->edit_field], 8, 26, 2);

    tft.setTextDatum(TR_DATUM);
    tft.setTextColor(C_TEXT, C_BG);
    tft.drawString(elide(field_value(ui, ui->edit_field), b, sizeof b, 30),
                   CYD_LAYOUT_W - 8, 26, 2);

    for (int r = 0; r < CYD_KB_ROWS; r++) {
        for (int c = 0; c < CYD_KB_COLS; c++) {
            char ch = cyd_ui_kb_char(c, r, ui->kb_shift);
            if (!ch)
                continue;
            cyd_rect_t k = CYD_KB_KEY(c, r);
            char lbl[2] = { ch, 0 };
            fill_rect(k, C_PANEL);
            tft.drawRect(k.x, k.y, k.w, k.h, C_ACCENT);
            tft.setTextDatum(MC_DATUM);
            tft.setTextColor(C_TEXT, C_PANEL);
            tft.drawString(lbl, k.x + k.w / 2, k.y + k.h / 2, 2);
        }
    }

    toggle(CYD_KB_SHIFT, "SHIFT", ui->kb_shift);
    button(CYD_KB_BKSP,   "DEL",    false);
    button(CYD_KB_CANCEL, "CANCEL", false);
    button(CYD_KB_OK,     "OK",     true);
}

static void draw_actions(const cyd_ui_t *ui)
{
    tft.setTextDatum(TL_DATUM);
    tft.setTextColor(C_DIM, C_BG);
    tft.drawString("RESET and REBOOT ask for confirmation.", 10, 58, 2);
    tft.drawString("Fan boost is immediate and reversible.", 10, 76, 2);

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
    } else if (ui->pending == CYD_ACTION_SET_POOL) {
        what = "CHANGE THE POOL?";
        /* Say that it persists. This rewrites /boot/am01-miner.conf,
         * so it is not a runtime tweak that a restart undoes. */
        note = "Saved to /boot; survives a reflash.";
    }

    tft.setTextDatum(MC_DATUM);
    tft.setTextColor(C_BAD, C_BG);
    tft.drawString(what, CYD_LAYOUT_W / 2, 70, 4);
    tft.setTextColor(C_DIM, C_BG);
    tft.drawString(note, CYD_LAYOUT_W / 2, 104, 2);

    /* NO is the wide left button and YES the narrow right one -- the easy
     * target is the harmless one. Checked by test_cyd_ui.c, which asserts
     * YES is no larger than NO. */
    button(CYD_CONFIRM_NO,  "NO",  false);
    button(CYD_CONFIRM_YES, "YES", true);
}

/* ---- entry point ------------------------------------------------------ */

void cyd_ui_draw(cyd_ui_t *ui, const cyd_status_t *st)
{
    if (!ui || !st)
        return;

    tft.fillScreen(C_BG);
    /* The honeycomb goes under EVERY screen, not just glance -- it is the
     * backdrop on all five of odo-miner's, and leaving it off is most of why
     * this panel did not read as the same product. */
    hexbg();

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
    case CYD_SCREEN_POOL:
        header("POOL", st, ui->link_down);
        draw_pool(ui);
        break;
    case CYD_SCREEN_KEYBOARD:
        header(POOL_LABELS[ui->edit_field], st, ui->link_down);
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
    if (ui->link_down) {
        int by = CYD_LAYOUT_H / 2 - 18;
        tft.fillRect(0, by, CYD_LAYOUT_W, 36, C_BAD);
        tft.setTextDatum(MC_DATUM);
        tft.setTextColor(C_TEXT, C_BAD);
        tft.drawString("MINER DOWN", CYD_LAYOUT_W / 2, by + 18, 4);
    }
}
