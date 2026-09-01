/*
 * thermal_am01.c -- see thermal_am01.h for why this replaces the Cyclone V's
 * thermal.c wholesale rather than being ported from it.
 *
 * Short version: that one drives a DS18B20 over a bit-banged one-wire bus on
 * an Avalon-MM PIO reached through /dev/mem. None of those three things exist
 * on this board. The numbers it wants are already published by the FPGA on
 * the register bus the daemon is using anyway.
 */

#include "thermal_am01.h"
#include "miner_io_gpio.h"
#include "am01_gpio_bus.h"

#include <stdio.h>
#include <errno.h>
#include <string.h>

/* Tach pulses per revolution. Two is the near-universal convention for
 * 3- and 4-wire PC fans and matches what this board measures: 138 pulses/s
 * observed at full duty on 2026-08-30, i.e. 4140 rpm, which is right for the
 * fan fitted. Wrong here and the dashboard is confidently wrong by a factor
 * of two, with nothing to give it away. */
#define TACH_PULSES_PER_REV 2

static int g_ready = 0;      /* a plausible temperature has been read     */
static int g_floor_pct = 0;  /* what software last asked for, 0 = auto    */

/* One place that decides whether we can talk to the FPGA at all, so every
 * entry point below fails the same way instead of each inventing its own. */
static am01_bus_t *bus(void)
{
    return miner_io_gpio_bus();
}

int thermal_init(void)
{
    g_ready = 0;
    g_floor_pct = 0;

    am01_bus_t *b = bus();
    if (!b) {
        fprintf(stderr, "[thermal] GPIO bus not open -- "
                        "miner_io_pipe_init() must run first\n");
        return -1;
    }

    /* Prove the path end to end rather than assuming it. A bitstream older
     * than 0x0102 has no ADDR_TEMP and returns ENOTSUP; one that has only
     * just configured returns EAGAIN until the first XADC conversion lands,
     * a few microseconds later. Those are different problems and only the
     * first is fatal, so they are reported differently -- the alternative is
     * a "sensor failed" message that sends someone looking at hardware when
     * they needed to wait 10 microseconds. */
    double c = 0.0;
    for (int attempt = 0; attempt < 3; attempt++) {
        if (am01_bus_read_temp(b, &c) == 0) {
            g_ready = 1;
            fprintf(stderr, "[thermal] XADC die temperature %.1f C "
                            "(fan curve runs in fabric)\n", c);
            return 0;
        }
        if (errno == ENOTSUP) {
            fprintf(stderr, "[thermal] bitstream has no temperature register "
                            "(needs VERSION >= 0x0102)\n");
            return -1;
        }
        /* EAGAIN: no conversion yet. Retry rather than fail. */
    }

    fprintf(stderr, "[thermal] no XADC conversion after 3 tries: %s\n",
            strerror(errno));
    return -1;
}

int thermal_read_c(int *temp_c)
{
    am01_bus_t *b = bus();
    if (!b || !temp_c)
        return -1;

    double c = 0.0;
    if (am01_bus_read_temp(b, &c) != 0)
        return -1;

    /* Round rather than truncate. The dashboard shows whole degrees and a
     * truncating conversion reads persistently ~0.5 C cold, which is exactly
     * the kind of small consistent error nobody ever notices. */
    *temp_c = (int)(c >= 0.0 ? c + 0.5 : c - 0.5);
    g_ready = 1;
    return 0;
}

void thermal_fan_set_pct(int pct)
{
    am01_bus_t *b = bus();
    if (!b)
        return;

    if (pct < 0)   pct = 0;
    if (pct > 100) pct = 100;

    /* 0-100% -> 0-255 duty. Rounded, so 100 maps to 255 and not 254. */
    uint8_t floor = (uint8_t)((pct * 255 + 50) / 100);

    if (am01_bus_fan(b, 1, floor, NULL, NULL) == 0)
        g_floor_pct = pct;
}

void thermal_fan_update(int temp_c)
{
    /* Deliberately nothing. The curve is closed-loop in fabric off XADC, so
     * it is already correct -- and correct before Linux has booted, which is
     * the property that matters on a design that free-runs at full power the
     * moment it configures from flash.
     *
     * The parameter is unused rather than removed so this file stays diffable
     * against the Cyclone V thermal.c it replaces, and so the caller in
     * miner_pipe_am01.c needs no change. */
    (void)temp_c;
}

int thermal_fan_state(void)
{
    am01_bus_t *b = bus();
    if (!b)
        return -1;

    uint8_t duty = 0;
    if (am01_bus_fan(b, 0, 0, &duty, NULL) != 0)
        return -1;

    /* The ACTUAL duty, read back, not g_floor_pct. They differ whenever the
     * fabric curve is above the floor -- which is most of the time -- and
     * reporting what software asked for would show a fan speed the fan is
     * not running at. */
    return (duty * 100 + 127) / 255;
}

int thermal_tach_rpm(int window_ms)
{
    /* Ignored: the FPGA counts continuously and reports pulses/sec, so there
     * is no sampling window to honour. Kept in the signature so this drops in
     * for the Cyclone V version unchanged. Not sleeping for it is a bonus --
     * the caller passes 200, and that was 200 ms of a thread doing nothing. */
    (void)window_ms;

    am01_bus_t *b = bus();
    if (!b)
        return -1;

    uint8_t duty = 0, tach_hz = 0;
    if (am01_bus_fan(b, 0, 0, &duty, &tach_hz) != 0)
        return -1;

    /* Zero pulses is a READING, not an error: with a non-zero duty it means a
     * stalled or disconnected fan, which is precisely the thing worth seeing
     * on a dashboard. Returning -1 would hide a dead fan behind the same "--"
     * used for "no sensor". */
    return ((int)tach_hz * 60) / TACH_PULSES_PER_REV;
}

int thermal_reset_pressed(void)
{
    /* No reset button in this design. Reported as "not pressed" rather than
     * as an error so the daemon's 10 Hz poll stays harmless. */
    return 0;
}

void thermal_shutdown(void)
{
    am01_bus_t *b = bus();
    if (b)
        am01_bus_fan(b, 1, 0, NULL, NULL);   /* floor 0 = fully automatic */

    g_floor_pct = 0;
    g_ready = 0;
}
