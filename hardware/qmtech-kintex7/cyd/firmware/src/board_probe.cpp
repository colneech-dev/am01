/*
 * board_probe.cpp -- is this panel alive, and is touch on the right bus?
 *
 * Standalone. No link, no protocol, no UI, nothing from the rest of this
 * directory. Flash it, watch the screen, poke it, read the serial console.
 *
 *   pio run -e probe -t upload && pio device monitor
 *
 * WHY THIS EXISTS AT ALL, given it displays nothing useful: the ILI9341 on JP5
 * consumed a session and was never made to work, and the reason it was so
 * expensive is that display, wiring, driver and protocol were all unproven at
 * once. Every white screen had four possible causes and no way to separate
 * them. This answers the two hardware questions on their own, before anything
 * is wired to the miner, so that a later failure has somewhere to be isolated
 * to.
 *
 * What a PASS looks like:
 *   - four colour bars, then a white->black sweep, then a text panel
 *   - touching anywhere prints raw and mapped coordinates over serial
 *   - the four corners read roughly (0,0) (239,0) (0,319) (239,319)
 *
 * What the common failures look like:
 *   - backlight on, screen white          -> panel init; try ILI9341_DRIVER
 *                                            instead of ILI9341_2_DRIVER
 *   - colours wrong/inverted              -> same flag, other direction
 *   - display fine, no touch output ever  -> touch is on the OTHER SPI bus;
 *                                            check TOUCH_* pins below, and
 *                                            that TOUCH_CS is NOT set for
 *                                            TFT_eSPI (see platformio.ini)
 */

#include <Arduino.h>
#include <SPI.h>
#include <TFT_eSPI.h>
#include <XPT2046_Touchscreen.h>

/* Touch, on VSPI -- its own bus, separate from the display's HSPI. These are
 * fixed by the ESP32-2432S028R's PCB, not a choice. */
#define TOUCH_SCLK 25
#define TOUCH_MOSI 32
#define TOUCH_MISO 39
#define TOUCH_CS_PIN 33
#define TOUCH_IRQ 36

static TFT_eSPI tft;
static SPIClass touch_spi(VSPI);
static XPT2046_Touchscreen touch(TOUCH_CS_PIN, TOUCH_IRQ);

/* Raw XPT2046 counts at the corners. These are NOT calibrated for this
 * specific panel -- they are the usual range, good enough to prove touch works
 * and to tell a dead controller from a mis-mapped one. Real calibration
 * belongs in the UI, once there is one. */
static const int RAW_X_MIN = 200, RAW_X_MAX = 3700;
static const int RAW_Y_MIN = 240, RAW_Y_MAX = 3800;

static void banner(void)
{
    tft.fillScreen(TFT_BLACK);
    tft.setTextColor(TFT_WHITE, TFT_BLACK);
    tft.setTextDatum(TL_DATUM);

    tft.drawString("AM01 CYD probe", 8, 8, 4);
    tft.setTextColor(TFT_DARKGREY, TFT_BLACK);
    tft.drawString("display: OK if you can read this", 8, 44, 2);
    tft.drawString("touch:   press anywhere", 8, 62, 2);

    tft.setTextColor(TFT_GREEN, TFT_BLACK);
    tft.drawString("watch the serial console", 8, 92, 2);
}

void setup(void)
{
    Serial.begin(115200);
    /* The USB console comes up after the ESP32 does; without this the first
     * few lines -- the ones identifying the build -- are lost, which is
     * exactly the output you want when a board is not behaving. */
    delay(300);

    Serial.println();
    Serial.println("=== AM01 CYD board probe ===");
    Serial.printf("built %s %s\n", __DATE__, __TIME__);

    pinMode(TFT_BL, OUTPUT);
    digitalWrite(TFT_BL, HIGH);

    tft.init();
    tft.setRotation(0);          /* portrait, 240x320 */

    Serial.printf("tft: %dx%d\n", tft.width(), tft.height());

    /* ---- colour bars ------------------------------------------------
     * Four flat colours, which distinguishes several failures at a glance:
     * all-white is no init, all-black is no data, and swapped red/blue is an
     * RGB/BGR mismatch rather than anything wrong with the wiring. */
    const uint16_t bars[4] = { TFT_RED, TFT_GREEN, TFT_BLUE, TFT_WHITE };
    const char    *names[4] = { "RED", "GREEN", "BLUE", "WHITE" };
    for (int i = 0; i < 4; i++) {
        tft.fillScreen(bars[i]);
        Serial.printf("bar: %s\n", names[i]);
        delay(500);
    }

    /* ---- a sweep, to show it is not one frozen frame ------------------ */
    for (int g = 255; g >= 0; g -= 15) {
        tft.fillScreen(tft.color565(g, g, g));
        delay(20);
    }

    touch_spi.begin(TOUCH_SCLK, TOUCH_MISO, TOUCH_MOSI, TOUCH_CS_PIN);
    touch.begin(touch_spi);
    touch.setRotation(0);

    banner();
    Serial.println("ready -- touch the panel");
}

void loop(void)
{
    static uint32_t last = 0;

    if (touch.touched()) {
        TS_Point p = touch.getPoint();

        int mx = map(p.x, RAW_X_MIN, RAW_X_MAX, 0, tft.width()  - 1);
        int my = map(p.y, RAW_Y_MIN, RAW_Y_MAX, 0, tft.height() - 1);
        mx = constrain(mx, 0, tft.width()  - 1);
        my = constrain(my, 0, tft.height() - 1);

        /* Raw AND mapped. Raw alone cannot be sanity-checked by eye; mapped
         * alone hides whether a bad reading came from the controller or from
         * the calibration constants above. */
        Serial.printf("touch raw=(%4d,%4d) z=%4d  mapped=(%3d,%3d)\n",
                      p.x, p.y, p.z, mx, my);

        tft.fillCircle(mx, my, 3, TFT_YELLOW);
        last = millis();
    }

    /* Clear the marks once the screen has been left alone, so a long session
     * does not end up as a solid block of yellow. */
    if (last && millis() - last > 3000) {
        banner();
        last = 0;
    }

    delay(20);
}
