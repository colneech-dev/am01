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
 *   am01_probe fan [floor]     force a duty floor (0-255), watch the tach
 *   am01_probe bl  <0|1>       backlight off/on, nothing else
 *   am01_probe panel           backlight + ILI9341 init + colour bars
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
    if (lcd_dat(b, 0x48) != 0) return -1;   /*   BGR, portrait */
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

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr,
            "usage: %s <fan [floor] | bl <0|1> | panel>\n"
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
    else { fprintf(stderr, "unknown command '%s'\n", argv[1]); rc = 2; }

    am01_bus_close(bus);
    return rc;
}
