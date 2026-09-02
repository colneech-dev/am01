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
#include <TFT_eSPI.h>

#include "cyd_ui.h"
#include "cyd_ui_layout.h"

/* odo-ui's palette, converted from its RGB565() macro. */
static inline uint16_t rgb(uint8_t r, uint8_t g, uint8_t b)
{
    return (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}
#define C_BG      rgb(16, 15, 11)
#define C_PANEL   rgb(26, 24, 18)
#define C_TEXT    rgb(242, 239, 230)
#define C_DIM     rgb(172, 165, 144)
#define C_OK      rgb(70, 200, 120)
#define C_WARN    rgb(224, 123, 58)
#define C_BAD     rgb(229, 86, 74)
#define C_ACCENT  rgb(240, 178, 60)

static TFT_eSPI tft;

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

static void header(const char *title, const cyd_status_t *st, bool link_down)
{
    tft.fillRect(0, 0, CYD_LAYOUT_W, 24, C_PANEL);
    tft.setTextDatum(TL_DATUM);
    tft.setTextColor(C_ACCENT, C_PANEL);
    tft.drawString(title, 8, 4, 2);

    /* Connection state, top right. THREE states, not two: the link being up
     * and the POOL being connected are different failures and want telling
     * apart -- "MINER DOWN" sends you to the Pi, "POOL" sends you to the
     * network. Collapsing them would send you to the wrong place. */
    const char *tag;
    uint16_t    tc;
    if (link_down)          { tag = "MINER DOWN"; tc = C_BAD;  }
    else if (!st->connected){ tag = "POOL";       tc = C_WARN; }
    else                    { tag = "OK";         tc = C_OK;   }
    tft.setTextDatum(TR_DATUM);
    tft.setTextColor(tc, C_PANEL);
    tft.drawString(tag, CYD_LAYOUT_W - 8, 4, 2);
}

/* ---- screens ---------------------------------------------------------- */

static void draw_glance(const cyd_status_t *st, bool link_down)
{
    char b[48];

    /* THE HASHRATE IS THE POINT OF THE PANEL, so it gets font 6 and the top
     * third to itself. Everything else is a supporting detail you go looking
     * for; this is the number you read from across the room. */
    cyd_fmt_hashrate(st->hashrate, b, sizeof b);
    tft.setTextDatum(MC_DATUM);
    tft.setTextColor(link_down ? C_DIM : C_ACCENT, C_BG);
    tft.drawString(b, CYD_LAYOUT_W / 2, 62, 6);

    int y = 104;
    row(y, "POOL", st->pool[0] ? st->pool : "--", C_TEXT);      y += 20;

    snprintf(b, sizeof b, "%llu / %llu",
             (unsigned long long)st->shares_accepted,
             (unsigned long long)st->shares_rejected);
    /* Rejects are the number worth colouring: any non-zero is worth a look,
     * and it is the first symptom of a stale bitstream after an epoch
     * rollover. */
    row(y, "ACC / REJ", b, st->shares_rejected ? C_WARN : C_OK); y += 20;

    cyd_fmt_temp(st->temp_c, b, sizeof b);
    row(y, "TEMP", b, st->temp_c >= 80 ? C_WARN : C_TEXT);       y += 20;

    cyd_fmt_fan(st->fan_rpm, st->fan_duty_pct, b, sizeof b);
    row(y, "FAN", b, C_TEXT);

    button(CYD_BTN_LEFT,  "DETAIL",   false);
    button(CYD_BTN_MID,   "SET",      false);
    button(CYD_BTN_RIGHT, "ACTIONS",  false);
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

static void draw_actions(void)
{
    tft.setTextDatum(TL_DATUM);
    tft.setTextColor(C_DIM, C_BG);
    tft.drawString("Both actions ask for confirmation.", 10, 60, 2);
    tft.drawString("Nothing here happens on one touch.", 10, 80, 2);

    button(CYD_BTN_LEFT,  "BACK",   false);
    button(CYD_BTN_MID,   "RESET",  false);
    button(CYD_BTN_RIGHT, "REBOOT", true);
}

static void draw_confirm(const cyd_ui_t *ui)
{
    const char *what = (ui->pending == CYD_ACTION_REBOOT)
                     ? "REBOOT THE MINER?" : "RESET STATISTICS?";
    const char *note = (ui->pending == CYD_ACTION_REBOOT)
                     ? "Mining stops until it comes back."
                     : "Share counters return to zero.";

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

    switch (ui->screen) {
    case CYD_SCREEN_GLANCE:
        header("AM01", st, ui->link_down);
        draw_glance(st, ui->link_down);
        break;
    case CYD_SCREEN_DETAIL:
        header("DETAIL", st, ui->link_down);
        /* The MINER'S clock, passed through, not the ESP32's: a CYD has no
         * RTC and NTP may never have run, so `now` comes from the status
         * object. See cyd_fmt_epoch_left_at(). */
        draw_detail(st, st->epoch ? st->epoch + st->uptime : 0);
        break;
    case CYD_SCREEN_SETTINGS:
        header("SETTINGS", st, ui->link_down);
        draw_settings(ui);
        break;
    case CYD_SCREEN_ACTIONS:
        header("ACTIONS", st, ui->link_down);
        draw_actions();
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
