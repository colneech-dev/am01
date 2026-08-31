/*
 * am01_probe.c -- drive the fan and the panel directly, without the miner.
 *
 * WHY. Both of these were, until now, only reachable through odo-miner:
 *
 *   * the panel is initialised and pushed from miner_io_pipe_wait()'s idle
 *     path, which is inside the POST-CONNECTION mining loop. So a screen could
 *     not be brought up without a working pool -- exactly backwards, and it is
 *     why the display sat dark for days while the actual fault was a missing
 *     environment variable and an unloaded vfb module.
 *
 *   * fan duty is chosen in fabric from the XADC curve. Software can raise the
 *     floor, but nothing exposed that, so "is the PWM wire connected?" had no
 *     answer short of a scope.
 *
 * Neither of those is a hardware limitation; both are just missing tools.
 *
 * Run as root with odo-miner stopped -- the GPIO chip is opened exclusively.
 *
 *   am01_probe flash [n]       flash the WHOLE panel via 0x23/0x22, no data
 *   am01_probe fan [floor]     force a duty floor (0-255), watch the tach
 *   am01_probe bl  <0|1>       backlight off/on, nothing else
 *   am01_probe panel           backlight + ILI9341 init + colour bars
 *   am01_probe fill [size]     init + CASET/PASET/RAMWR on a SMALL square only
 *   am01_probe raw [n] [rgb565hex]   init + RAMWR directly, NO CASET/PASET
 */

#define _POSIX_C_SOURCE 200809L

#include "am01_gpio_bus.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <time.h>

#define W 320
#define H 240

static void nap_ms(long ms)
{
    struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

/* ---- fan ------------------------------------------------------------- */
static int cmd_fan(am01_bus_t *bus, int argc, char **argv)
{
    int have_floor = (argc > 2);
    unsigned floor = have_floor ? (unsigned)strtoul(argv[2], NULL, 0) : 0;
    if (floor > 255) floor = 255;

    if (have_floor)
        printf("forcing duty floor to %u/255 (%.0f%%)\n", floor, floor * 100.0 / 255.0);
    else
        printf("observing only -- pass a floor 0-255 to force duty\n");

    printf("\n  %-8s %-14s %s\n", "sample", "duty", "tach");
    for (int i = 0; i < 10; i++) {
        uint8_t duty = 0, tach = 0;
        if (am01_bus_fan(bus, have_floor, (uint8_t)floor, &duty, &tach) != 0) {
            fprintf(stderr, "am01_bus_fan failed\n");
            return 1;
        }
        printf("  %-8d %3u/255 (%3.0f%%)  %u pulses/s  (~%u rpm)\n",
               i, duty, duty * 100.0 / 255.0, tach, tach * 30u);
        fflush(stdout);
        nap_ms(1000);
    }

    printf("\nThe duty column is what the FPGA pin is actually driving.\n");
    if (have_floor && floor >= 200)
        printf("At this floor the fan should be audibly faster. If it is NOT,\n"
               "the blue PWM wire is not on JP5 pin 43 -- and a 4-wire fan with\n"
               "no PWM connection runs at FULL speed, so a fan that is spinning\n"
               "slowly with duty pinned high is the clearest sign of that.\n");
    printf("A tach of 0 with non-zero duty is a fan that is stalled, has no\n"
           "tach wire, or whose tach is not reaching JP5 pin 44. Note that a\n"
           "12V fan on this board's 5V rail commonly spins but reports nothing.\n");
    return 0;
}

/* ---- backlight only --------------------------------------------------- */
static int cmd_bl(am01_bus_t *bus, int argc, char **argv)
{
    int on = (argc > 2) ? atoi(argv[2]) : 1;
    /* reset_n high = out of reset. Driving reset low here would be a way to
     * make the panel blank deliberately, but that is not what this is for. */
    if (am01_bus_lcd_ctrl(bus, 1, on ? 1 : 0) != 0) {
        fprintf(stderr, "am01_bus_lcd_ctrl failed\n");
        return 1;
    }
    printf("backlight %s (LCD_CTRL reset_n=1 backlight=%d)\n",
           on ? "ON" : "OFF", on ? 1 : 0);
    printf("\nThis is the single cheapest test of the panel wiring: it touches\n"
           "only VCC, GND and the LED/BL line on JP5 pin 9. If the backlight\n"
           "does not change, nothing else about the display can work either,\n"
           "and the fault is power or that one wire -- not SPI.\n");
    return 0;
}

/* ---- panel: init + colour bars ---------------------------------------- */
static int lcd_cmd(am01_bus_t *b, uint8_t c) { return am01_bus_lcd_cmd(b, c); }
/* Parameters are ONE byte and must use the 8-bit DC=1 register. Through the
 * 16-bit ADDR_LCD_DATA they put a second byte on the wire per parameter, which
 * corrupts CASET/PASET -- see am01_bus_lcd_data8(). */
static int lcd_dat(am01_bus_t *b, uint8_t d) { return am01_bus_lcd_data8(b, d); }

static int ili9341_init(am01_bus_t *b)
{
    /* Minimal, deliberately: software reset, sleep out, 16-bit pixel format,
     * memory access control, display on. Enough to light a picture; not the
     * vendor's full gamma incantation. */
    if (lcd_cmd(b, 0x01) != 0) return -1;   /* SWRESET */
    nap_ms(150);
    if (lcd_cmd(b, 0x11) != 0) return -1;   /* SLPOUT  */
    nap_ms(150);
    if (lcd_cmd(b, 0x3A) != 0) return -1;   /* COLMOD  */
    if (lcd_dat(b, 0x55) != 0) return -1;   /*   16bpp */
    if (lcd_cmd(b, 0x36) != 0) return -1;   /* MADCTL  */
    /* 0x68 = MV|MX|BGR. MV (row/column exchange) is required: this panel's
     * native orientation is 240 columns x 320 rows, but W=320/H=240 below and
     * every CASET/PASET call assume landscape. Without MV, CASET's column end
     * (319) exceeds the native 240-column max and the panel silently rejects
     * the window -- RAMWR then has nowhere valid to write. Confirmed on
     * hardware 2026-08-31: am01_probe raw (no CASET/PASET, panel's own
     * default window) reliably shows pixels; anything using CASET/PASET at
     * 320x240 coordinates showed nothing at all until this bit was set. */
    if (lcd_dat(b, 0x68) != 0) return -1;   /*   MV, MX, BGR: landscape */
    if (lcd_cmd(b, 0x29) != 0) return -1;   /* DISPON  */
    nap_ms(50);
    return 0;
}

static int set_window(am01_bus_t *b, int x0, int y0, int x1, int y1)
{
    if (lcd_cmd(b, 0x2A) != 0) return -1;
    if (lcd_dat(b, (uint8_t)(x0 >> 8)) != 0) return -1;
    if (lcd_dat(b, (uint8_t)(x0 & 0xFF)) != 0) return -1;
    if (lcd_dat(b, (uint8_t)(x1 >> 8)) != 0) return -1;
    if (lcd_dat(b, (uint8_t)(x1 & 0xFF)) != 0) return -1;
    if (lcd_cmd(b, 0x2B) != 0) return -1;
    if (lcd_dat(b, (uint8_t)(y0 >> 8)) != 0) return -1;
    if (lcd_dat(b, (uint8_t)(y0 & 0xFF)) != 0) return -1;
    if (lcd_dat(b, (uint8_t)(y1 >> 8)) != 0) return -1;
    if (lcd_dat(b, (uint8_t)(y1 & 0xFF)) != 0) return -1;
    return lcd_cmd(b, 0x2C);   /* RAMWR */
}

/* The smallest test that can possibly show something.
 *
 * 0x23 DISPON-ALL-PIXELS-ON and 0x22 ALL-PIXELS-OFF take NO parameters, so
 * this exercises only: chip select, DC low, SCLK, MOSI, and one byte. No
 * pixel data, no address window, no 8-bit parameter register. If the panel
 * does not visibly flash under this, nothing more elaborate can work either,
 * and the fault is a wire or a logic threshold rather than anything in the
 * driver.
 *
 * Deliberately does NOT send SWRESET: a reset would reload defaults and hide
 * a panel that is already configured, and the point here is to change one
 * visible thing with the fewest possible bytes. */
static int cmd_flash(am01_bus_t *bus, int argc, char **argv)
{
    int reps = (argc > 2) ? atoi(argv[2]) : 6;
    if (reps < 1) reps = 1;

    printf("backlight on, panel out of reset\n");
    if (am01_bus_lcd_ctrl(bus, 1, 1) != 0) return 1;
    nap_ms(50);

    /* Wake it, in case it is asleep, then make sure the display is enabled.
     * Both are parameterless. */
    if (lcd_cmd(bus, 0x11) != 0) return 1;   /* SLPOUT  */
    nap_ms(150);
    if (lcd_cmd(bus, 0x29) != 0) return 1;   /* DISPON  */
    nap_ms(50);

    printf("\nflashing the whole panel %d times, ~1s each way.\n", reps);
    printf("WATCH THE SCREEN -- this needs no pixel data at all.\n\n");

    for (int i = 0; i < reps; i++) {
        if (lcd_cmd(bus, 0x23) != 0) return 1;   /* all pixels ON  */
        printf("  %d: ALL PIXELS ON  (expect white/bright)\n", i);
        fflush(stdout);
        nap_ms(1000);
        if (lcd_cmd(bus, 0x22) != 0) return 1;   /* all pixels OFF */
        printf("  %d: ALL PIXELS OFF (expect black)\n", i);
        fflush(stdout);
        nap_ms(1000);
    }

    lcd_cmd(bus, 0x13);   /* back to normal display mode */

    printf("\nIf the panel FLASHED: the command path is good -- CS, DC, SCLK\n"
           "and MOSI all reach it, and the fault is in pixel data or the\n"
           "address window, both of which are software.\n\n"
           "If it did NOT flash: no command is reaching the panel. That is a\n"
           "wire (CS pin 6, DC pin 7, SCLK pin 3, MOSI pin 4), or the module's\n"
           "inputs are not accepting 3.3V as a logic high -- which a 5V-powered\n"
           "module with an HC-family level shifter will do.\n");
    return 0;
}

static int cmd_panel(am01_bus_t *bus)
{
    printf("backlight on, reset released...\n");
    if (am01_bus_lcd_ctrl(bus, 1, 1) != 0) {
        fprintf(stderr, "LCD_CTRL write failed -- the bus is not reaching the FPGA\n");
        return 1;
    }
    nap_ms(120);

    printf("ILI9341 init...\n");
    if (ili9341_init(bus) != 0) {
        fprintf(stderr, "init sequence failed on the bus\n");
        return 1;
    }

    /* Eight vertical bars. Bars rather than a flat fill on purpose: a solid
     * colour cannot distinguish a working panel from a stuck data line, and
     * wrong bar ORDER or wrong colours says the byte/word order is off rather
     * than the wiring. */
    static const uint16_t bar[8] = {
        0xFFFF, /* white  */
        0xFFE0, /* yellow */
        0x07FF, /* cyan   */
        0x07E0, /* green  */
        0xF81F, /* magenta*/
        0xF800, /* red    */
        0x001F, /* blue   */
        0x0000  /* black  */
    };

    printf("painting colour bars (%d x %d, ~%d writes at ~20us each)...\n",
           W, H, W * H);
    if (set_window(bus, 0, 0, W - 1, H - 1) != 0) {
        fprintf(stderr, "window set failed\n");
        return 1;
    }

    for (int y = 0; y < H; y++) {
        for (int x = 0; x < W; x++) {
            uint16_t c = bar[(x * 8) / W];
            /* RAMWR takes 16-bit pixels; the bus's 16-bit data path writes one
             * pixel per transfer. */
            if (am01_bus_lcd_data(bus, c) != 0) {
                fprintf(stderr, "\npixel write failed at (%d,%d)\n", x, y);
                return 1;
            }
        }
        if ((y % 24) == 0) { printf("  row %d/%d\n", y, H); fflush(stdout); }
    }

    printf("\ndone.\n");
    printf("  8 vertical bars, left to right:\n");
    printf("  white yellow cyan green magenta red blue black\n");
    printf("\nIf you see them, the whole path works: bus, FPGA SPI master,\n"
           "and every panel wire. If you see bars in the WRONG order or wrong\n"
           "colours, the path works and the byte order is wrong. If the screen\n"
           "is lit but blank, MOSI/SCLK/DC/CS is the place to look, not power.\n");
    return 0;
}

/* Isolates CASET/PASET/RAMWR from the 76800-write burst in cmd_panel().
 *
 * cmd_panel() showed backlight + init working (screen lights) but no bar
 * image, even after the wiring pass that fixed the dimming. This writes the
 * same address-window + RAMWR sequence, just on a `size x size` square (a
 * few hundred writes, not 76800), all solid red so any visible red patch --
 * anywhere on the screen -- proves CASET/PASET/RAMWR itself works and the
 * fault is specific to a long sustained burst, not the command sequence. */
static int cmd_fill(am01_bus_t *bus, int argc, char **argv)
{
    int size = (argc > 2) ? atoi(argv[2]) : 20;
    if (size < 1) size = 1;

    printf("backlight on, reset released...\n");
    if (am01_bus_lcd_ctrl(bus, 1, 1) != 0) return 1;
    nap_ms(120);

    printf("ILI9341 init...\n");
    if (ili9341_init(bus) != 0) {
        fprintf(stderr, "init sequence failed on the bus\n");
        return 1;
    }

    printf("painting a %dx%d solid red square at (0,0), %d writes...\n",
           size, size, size * size);
    if (set_window(bus, 0, 0, size - 1, size - 1) != 0) {
        fprintf(stderr, "window set failed\n");
        return 1;
    }
    for (int i = 0; i < size * size; i++) {
        if (am01_bus_lcd_data(bus, 0xF800 /* red */) != 0) {
            fprintf(stderr, "\npixel write failed at index %d\n", i);
            return 1;
        }
    }

    printf("\ndone.\n"
           "If you see a small red square in the top-left corner: CASET/PASET/\n"
           "RAMWR all work, and the panel test's blank result is specific to\n"
           "the long 76800-write burst (look at sustained timing/power, not\n"
           "the command sequence).\n"
           "If you see NOTHING (still blank/white): the address-window or\n"
           "RAMWR sequence itself is not landing, regardless of burst length.\n");
    return 0;
}

/* cmd_fill() showed even 400 writes produce nothing. Init already proves a
 * SINGLE lcd_dat() (DATA8) write works (COLMOD, MADCTL both land -- the
 * panel lights up). CASET/PASET are the only place that sends FOUR DATA8
 * writes back-to-back with no command byte between them -- a pattern never
 * otherwise exercised. This skips CASET/PASET entirely and writes pixels
 * straight after RAMWR, relying on the ILI9341's power-on-default window
 * (the full screen). If pixels appear ANYWHERE, CASET/PASET's back-to-back
 * DATA8 writes are the fault, not RAMWR or the pixel path itself. */
static int cmd_raw(am01_bus_t *bus, int argc, char **argv)
{
    int n = (argc > 2) ? atoi(argv[2]) : 400;
    if (n < 1) n = 1;
    uint16_t colour = (argc > 3) ? (uint16_t)strtoul(argv[3], NULL, 16) : 0x07E0;

    printf("backlight on, reset released...\n");
    if (am01_bus_lcd_ctrl(bus, 1, 1) != 0) return 1;
    nap_ms(120);

    printf("ILI9341 init...\n");
    if (ili9341_init(bus) != 0) {
        fprintf(stderr, "init sequence failed on the bus\n");
        return 1;
    }

    printf("RAMWR directly (NO CASET/PASET), %d writes of colour 0x%04x...\n",
           n, colour);
    if (lcd_cmd(bus, 0x2C) != 0) {   /* RAMWR, no window set first */
        fprintf(stderr, "RAMWR command failed\n");
        return 1;
    }
    for (int i = 0; i < n; i++) {
        if (am01_bus_lcd_data(bus, colour) != 0) {
            fprintf(stderr, "\npixel write failed at index %d\n", i);
            return 1;
        }
    }

    printf("\ndone.\n"
           "If you see ANY green pixels anywhere on screen: RAMWR and the\n"
           "pixel data path both work. The fault is specific to CASET/PASET's\n"
           "back-to-back DATA8 writes.\n"
           "If you see NOTHING: RAMWR or the 16-bit pixel data path itself\n"
           "(ADDR_LCD_DATA, not DATA8) is the fault, not CASET/PASET.\n");
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr,
            "usage: %s <fan [floor] | bl <0|1> | panel | fill [size] | raw [n]>\n"
            "  run as root, with odo-miner stopped\n", argv[0]);
        return 2;
    }

    const char *chip = getenv("AM01_GPIOCHIP");
    am01_bus_t *bus = am01_bus_open(chip);
    if (!bus) {
        fprintf(stderr, "am01_bus_open failed (run as root, stop odo-miner first)\n");
        return 1;
    }

    uint16_t ver = 0;
    if (am01_bus_read_version(bus, &ver) == 0)
        printf("FPGA VERSION 0x%04x\n\n", ver);

    int rc;
    if      (!strcmp(argv[1], "fan"))   rc = cmd_fan(bus, argc, argv);
    else if (!strcmp(argv[1], "bl"))    rc = cmd_bl(bus, argc, argv);
    else if (!strcmp(argv[1], "panel")) rc = cmd_panel(bus);
    else if (!strcmp(argv[1], "flash")) rc = cmd_flash(bus, argc, argv);
    else if (!strcmp(argv[1], "fill"))  rc = cmd_fill(bus, argc, argv);
    else if (!strcmp(argv[1], "raw"))   rc = cmd_raw(bus, argc, argv);
    else { fprintf(stderr, "unknown command '%s'\n", argv[1]); rc = 2; }

    am01_bus_close(bus);
    return rc;
}
