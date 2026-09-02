/*
 * cyd_fmt.c -- the four value formatters declared in cyd_ui.h.
 *
 * SEPARATE FROM THE DRAWING CODE, and separate on purpose. These are pure
 * functions of a value and a buffer: no TFT, no Arduino, no board. That means
 * they compile and run on a PC, and sim/test_cyd_fmt.c exercises every branch
 * in about a millisecond -- including the ones that only occur when the miner
 * is reporting something it could not read.
 *
 * That matters more here than it looks. cyd_ui.h calls these "the places a
 * panel most easily lies", and it is right: every one of them turns a number
 * that means "I do not know" into text a person will believe. A panel reading
 * "-1 C" next to a running miner says the board is broken. A panel reading
 * "0.0 H/s" during startup says the miner is dead. Neither is true, and
 * neither is detectable by looking at the panel -- which is exactly the class
 * of bug that cost this project a session on the ILI9341.
 */

#include "cyd_ui.h"

#include <stdio.h>
#include <string.h>

/* Every function here writes SOMETHING, always NUL-terminated, even when the
 * buffer is absurd or the pointer is null. A formatter that leaves a buffer
 * untouched on an edge case hands the drawing code whatever was on the stack,
 * and a panel that paints stack garbage over a hashrate is worse than one
 * that paints "--". */
static void put(char *out, int n, const char *s)
{
    if (!out || n <= 0)
        return;
    (void)snprintf(out, (size_t)n, "%s", s);
}

/*
 * Hashrate. "68.4 MH/s".
 *
 * Scaled to a unit, not printed raw: 68356137 H/s is unreadable at a glance
 * and the panel exists to be read at a glance.
 *
 * NEGATIVE AND NaN BOTH BECOME "--". Neither can happen from a healthy miner,
 * which is the point -- if one ever does, the honest answer is that the panel
 * does not know, not a confidently-rendered nonsense number. NaN is checked
 * as x != x so this needs no math.h and no -ffast-math surprises.
 */
void cyd_fmt_hashrate(double h_per_s, char *out, int n)
{
    if (!out || n <= 0)
        return;

    if (h_per_s != h_per_s || h_per_s < 0.0) {  /* NaN, or impossible */
        put(out, n, "--");
        return;
    }

    /* Zero is NOT unknown -- it is a real, meaningful reading during startup
     * and after a stall, and flattening it to "--" would hide a stopped
     * miner behind the same glyph used for a reporting gap. */
    if (h_per_s < 1000.0)
        (void)snprintf(out, (size_t)n, "%.0f H/s", h_per_s);
    else if (h_per_s < 1000000.0)
        (void)snprintf(out, (size_t)n, "%.1f kH/s", h_per_s / 1e3);
    else if (h_per_s < 1000000000.0)
        (void)snprintf(out, (size_t)n, "%.1f MH/s", h_per_s / 1e6);
    else
        (void)snprintf(out, (size_t)n, "%.2f GH/s", h_per_s / 1e9);
}

/*
 * Temperature. "62 C", or "--" when unknown.
 *
 * THE -1 CASE IS NOT HYPOTHETICAL. The miner published temp_c = -1
 * permanently until 2026-09-01, and the web dashboard rendered it literally
 * as "-1", which reads as a board fault. sw/thermal_am01.c fixed the source
 * of it -- the daemon had been built against the Cyclone V's thermal.c, which
 * drives hardware this board does not have -- but a bus read can still fail,
 * so the sentinel is still reachable and this panel still must not print it.
 *
 * ANY NEGATIVE VALUE is unknown, not just -1. This started as a "<= -50"
 * guard on the reasoning that -1 was the sentinel and other negatives might
 * be real cold readings -- and test_cyd_fmt caught it immediately, because
 * that reasoning is incoherent. XADC reports DIE temperature, and a die with
 * a miner running on it sits far above ambient; it is never below zero while
 * there is anything to report. So a negative reading is a sentinel or a
 * decode error either way, and "-1 C" is the single most misleading thing
 * this panel could print -- it reads as a board fault.
 */
void cyd_fmt_temp(int temp_c, char *out, int n)
{
    if (!out || n <= 0)
        return;

    if (temp_c < 0) {
        put(out, n, "--");
        return;
    }
    (void)snprintf(out, (size_t)n, "%d C", temp_c);
}

/*
 * Fan. "1820 rpm (55%)", or "55%" when the tach is unreadable, or "--".
 *
 * Two independent values, and they fail independently -- which is why this
 * is one function rather than two. The tach needs an external 10k pull-up to
 * 3.3V that a given build may not have fitted (it was missing on this board
 * until 2026-08-30), while the duty cycle is always known because the FPGA
 * sets it and reports it back. Showing "-- rpm" while hiding a known 55% duty
 * would misreport a working fan as an unknown one.
 *
 * Both come from ADDR_FAN: [7:0] duty, [15:8] tach pulses/sec. Measured live
 * on 2026-09-01 as 55% / 3000 rpm at 57 C -- and 55% is exactly what the
 * fabric curve prescribes in the 55-70 C band, which is a useful thing to
 * know when deciding whether a reading is real.
 */
void cyd_fmt_fan(int rpm, int duty_pct, char *out, int n)
{
    if (!out || n <= 0)
        return;

    int have_rpm  = (rpm >= 0);
    int have_duty = (duty_pct >= 0 && duty_pct <= 100);

    if (have_rpm && have_duty)
        (void)snprintf(out, (size_t)n, "%d rpm (%d%%)", rpm, duty_pct);
    else if (have_rpm)
        (void)snprintf(out, (size_t)n, "%d rpm", rpm);
    else if (have_duty)
        (void)snprintf(out, (size_t)n, "%d%%", duty_pct);
    else
        put(out, n, "--");
}

/*
 * Time until the next epoch. "2d 15h", "15h 30m", "42m", or "ROLLED".
 *
 * ABSOLUTE UNIX SECONDS ARE USELESS ON A PANEL. What matters is how long
 * until the bitstream has to be rebuilt and reflashed -- and the rebuild is
 * ~1h35m, so "3h" and "30m" call for very different responses. This is the
 * one number on the panel with a deadline attached.
 *
 * ROLLED is not an error state: it means the rollover has passed, so unless
 * the bitstream was rebuilt the miner is now producing rejects. It is the
 * loudest thing this formatter can say, which is proportionate.
 *
 * Takes `now` explicitly rather than calling time(). The ESP32's clock is not
 * necessarily set, the caller knows what it trusts, and a function that reads
 * a global clock cannot be tested against a fixed instant.
 */
void cyd_fmt_epoch_left_at(uint32_t epoch_next, uint32_t now, char *out, int n)
{
    if (!out || n <= 0)
        return;

    if (epoch_next == 0) {
        put(out, n, "--");          /* never reported */
        return;
    }
    /* now == 0 means the miner's clock has not been received yet -- DETAIL is
     * reachable before the first STATUS lands. Without this the countdown is
     * computed from the unix epoch and renders "20700d 0h": a 56-year
     * countdown, on the one field whose whole purpose is a deadline. */
    if (now == 0) {
        put(out, n, "--");
        return;
    }
    if (now >= epoch_next) {
        put(out, n, "ROLLED");
        return;
    }

    uint32_t left = epoch_next - now;
    uint32_t days = left / 86400u;
    uint32_t hrs  = (left % 86400u) / 3600u;
    uint32_t mins = (left % 3600u) / 60u;

    if (days > 0)
        (void)snprintf(out, (size_t)n, "%ud %uh", days, hrs);
    else if (hrs > 0)
        (void)snprintf(out, (size_t)n, "%uh %um", hrs, mins);
    else
        (void)snprintf(out, (size_t)n, "%um", mins);
}
