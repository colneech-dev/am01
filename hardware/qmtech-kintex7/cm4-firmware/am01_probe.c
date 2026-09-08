/*
 * am01_probe.c -- drive the fan directly, without the miner.
 *
 * It drove the panel too, until 530b266 removed the ILI9341 and XPT2046
 * from the FPGA (VERSION 0x0205). Those subcommands went with it: the
 * registers no longer exist in fabric, so they could not work at any
 * level. Leaving them behind broke `make all` for three days, because
 * everyone builds the odo-miner target by name. The replacement panel is
 * the ESP32 CYD unit on the FPGA UART, tooled separately under cyd/.
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
int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr,
            "usage: %s fan [floor]\n"
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
    else { fprintf(stderr, "unknown command '%s'\n", argv[1]); rc = 2; }

    am01_bus_close(bus);
    return rc;
}
