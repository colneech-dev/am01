/*
 * am01_busbench -- measure GPIO-bus throughput, and say plainly whether
 * driving the ILI9341 panel through it is viable.
 *
 * Why this exists: the panel is 320x240 RGB565, so a full frame is 76,800
 * pixel writes, each one a 4-phase interlocked transaction over bit-banged
 * GPIO. Whether that is a 60ms refresh or a 6-second one changes the design
 * completely -- full-frame blits versus mandatory damage tracking -- and
 * guessing at it would mean building the wrong thing. So measure first.
 *
 * ADDR_LCD_DATA is used as the target because it is write-only and has no
 * side effects beyond clocking a word out of the FPGA's SPI shifter: no
 * readback, no state to corrupt, and it is the exact path a real frame push
 * would take. The panel need not even be attached -- the shifter runs
 * regardless, and what is being timed is the CM4->FPGA bus, which is the
 * bottleneck (the SPI side runs at bus_clk/8 in fabric).
 *
 * NOTE this must not run while odo-miner is up: the bus is opened
 * exclusively, so one of the two will fail with EBUSY. Stop the miner first.
 *
 *   am01_busbench [iterations] [gpiochip]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>

#include "am01_gpio_bus.h"

#define PANEL_W 320
#define PANEL_H 240

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void report(const char *what, long n, double secs)
{
    double per = secs / (double)n;
    double rate = (double)n / secs;
    printf("  %-28s %8ld ops in %7.3fs  ->  %9.1f ops/s  %8.1f us/op\n",
           what, n, secs, rate, per * 1e6);
}

int main(int argc, char **argv)
{
    long iters = (argc > 1) ? strtol(argv[1], NULL, 0) : 20000;
    const char *chip = (argc > 2) ? argv[2] : getenv("AM01_GPIOCHIP");

    if (iters < 100) {
        fprintf(stderr, "iterations must be >= 100\n");
        return 2;
    }

    am01_bus_t *bus = am01_bus_open(chip);
    if (!bus) {
        fprintf(stderr, "am01_bus_open failed: %s\n", strerror(errno));
        fprintf(stderr, "  If this says \"Device or resource busy\", odo-miner\n"
                        "  holds the bus. Stop it first:\n"
                        "      systemctl stop odo-miner\n");
        return 1;
    }

    uint16_t version = 0;
    if (am01_bus_read_version(bus, &version) != 0) {
        fprintf(stderr, "could not read VERSION -- is the FPGA configured?\n");
        am01_bus_close(bus);
        return 1;
    }
    printf("FPGA wrapper VERSION 0x%04x\n\n", version);

    /* Warm up: first transactions pay page-fault and cache costs that would
     * otherwise be blamed on the bus. */
    for (int i = 0; i < 200; i++)
        (void)am01_bus_lcd_data(bus, (uint16_t)i);

    printf("timing:\n");

    double t0 = now_s();
    long done = 0;
    for (long i = 0; i < iters; i++) {
        if (am01_bus_lcd_data(bus, (uint16_t)i) != 0) break;
        done++;
    }
    double write_s = now_s() - t0;
    if (done < iters)
        printf("  (stopped early at %ld: %s)\n", done, strerror(errno));
    report("LCD_DATA write (16-bit)", done, write_s);

    /* A read costs more than a write: the data lines must be turned around
     * before RD_N is asserted, so it is worth knowing separately -- touch
     * polling and LCD_STAT both pay it. */
    long rd_iters = (iters > 4000) ? 4000 : iters;
    uint16_t st = 0;
    t0 = now_s();
    long rdone = 0;
    for (long i = 0; i < rd_iters; i++) {
        if (am01_bus_read_status(bus, &st) != 0) break;
        rdone++;
    }
    double read_s = now_s() - t0;
    report("STATUS read (16-bit)", rdone, read_s);

    am01_bus_close(bus);

    if (done < 100) {
        fprintf(stderr, "\ntoo few successful writes to draw a conclusion\n");
        return 1;
    }

    /* What it means for the panel. */
    double per_write = write_s / (double)done;
    double full_frame = per_write * (double)(PANEL_W * PANEL_H);
    double line       = per_write * (double)PANEL_W;
    double tile16     = per_write * 16.0 * 16.0;

    printf("\nwhat this means for a %dx%d RGB565 panel:\n", PANEL_W, PANEL_H);
    printf("  full frame  (%6d px)  %8.3f s   %6.2f fps\n",
           PANEL_W * PANEL_H, full_frame, 1.0 / full_frame);
    printf("  one line    (%6d px)  %8.3f s\n", PANEL_W, line);
    printf("  16x16 tile  (%6d px)  %8.3f s\n", 256, tile16);

    printf("\nverdict: ");
    if (full_frame <= 0.05)
        printf("full-frame blits are fine (>=20fps).\n");
    else if (full_frame <= 0.5)
        printf("full frames are usable for a status UI, but damage\n"
               "         tracking would make it feel responsive.\n");
    else
        printf("full-frame refresh is NOT viable (%.1fs per frame).\n"
               "         The push daemon MUST track damaged regions and send\n"
               "         only changed tiles. At %.1f ms per 16x16 tile, a\n"
               "         handful of changed tiles per update is affordable.\n",
               full_frame, tile16 * 1e3);

    return 0;
}
