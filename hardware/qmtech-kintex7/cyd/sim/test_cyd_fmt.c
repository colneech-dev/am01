/*
 * test_cyd_fmt.c -- unit test for the CYD panel's value formatters.
 *
 * Runs on a PC in milliseconds, no board, no toolchain beyond cc:
 *
 *   cc -Wall -Wextra -I../firmware/include -I../host \
 *      -o /tmp/t test_cyd_fmt.c ../firmware/src/cyd_fmt.c && /tmp/t
 *
 * WHY BOTHER, for four functions that print numbers: because every one of
 * them converts a value meaning "I do not know" into text a person will read
 * and believe. Those paths are exactly the ones that never occur while you
 * are looking at the panel, and they are the ones that lie. "-1 C" beside a
 * healthy miner reads as a hardware fault; the -1 is live in the miner's
 * output right now.
 *
 * Written the way tb_found_path.v and tb_uart_bridge.v are, for the same
 * reason: those caught real bugs before a 1h35m bitstream, and this catches
 * them before a flash cycle and a walk to the miner.
 */

#include "cyd_ui.h"

#include <stdio.h>
#include <string.h>

static int errors = 0;
static int checks = 0;

static void expect(const char *got, const char *want, const char *what)
{
    checks++;
    if (strcmp(got, want) == 0) {
        printf("  PASS  %-46s -> \"%s\"\n", what, got);
    } else {
        printf("  FAIL  %-46s -> \"%s\" (wanted \"%s\")\n", what, got, want);
        errors++;
    }
}

int main(void)
{
    char b[64];

    printf("=== test_cyd_fmt ===\n");

    /* ---- hashrate ---------------------------------------------------- */
    printf("\n-- hashrate --\n");

    cyd_fmt_hashrate(68356137.0, b, sizeof b);
    expect(b, "68.4 MH/s", "the miner's actual measured rate");

    cyd_fmt_hashrate(0.0, b, sizeof b);
    /* NOT "--". Zero is a real reading -- a stalled miner -- and collapsing it
     * into the unknown glyph would hide a dead miner behind a reporting gap. */
    expect(b, "0 H/s", "zero is a READING, not unknown");

    cyd_fmt_hashrate(999.0, b, sizeof b);
    expect(b, "999 H/s", "just below the kH boundary");
    cyd_fmt_hashrate(1000.0, b, sizeof b);
    expect(b, "1.0 kH/s", "exactly at the kH boundary");
    cyd_fmt_hashrate(999999.0, b, sizeof b);
    expect(b, "1000.0 kH/s", "just below the MH boundary");
    cyd_fmt_hashrate(1000000.0, b, sizeof b);
    expect(b, "1.0 MH/s", "exactly at the MH boundary");
    cyd_fmt_hashrate(79200000.0, b, sizeof b);
    expect(b, "79.2 MH/s", "the rate the MMCM bump would give");
    cyd_fmt_hashrate(2500000000.0, b, sizeof b);
    expect(b, "2.50 GH/s", "GH range still formats");

    cyd_fmt_hashrate(-1.0, b, sizeof b);
    expect(b, "--", "a negative rate is impossible -> unknown");

    /* NaN via 0.0/0.0 without math.h. A double that is not equal to itself is
     * NaN by definition, which is how cyd_fmt.c detects it too. */
    {
        double zero = 0.0;
        cyd_fmt_hashrate(zero / zero, b, sizeof b);
        expect(b, "--", "NaN -> unknown, not \"nan MH/s\"");
    }

    /* ---- temperature ------------------------------------------------- */
    printf("\n-- temperature --\n");

    cyd_fmt_temp(62, b, sizeof b);
    expect(b, "62 C", "a normal die temperature");

    cyd_fmt_temp(-1, b, sizeof b);
    /* THE LIVE CASE. The miner runs as user 'miner', its thermal init fails on
     * /dev/mem, and it publishes -1. The web dashboard renders that as "-1"
     * today, which reads as a board fault rather than a reporting gap. */
    expect(b, "--", "-1 is the miner's \"could not read\" sentinel");

    cyd_fmt_temp(0, b, sizeof b);
    expect(b, "0 C", "0 C is cold, not unknown");
    /* This pair used to assert "-10 C" was a real reading while -1 was a
     * sentinel. That is incoherent, and holding both is what let the bug
     * through: XADC reports DIE temperature, and a die with a miner running
     * on it is never below ambient, let alone below zero. Every negative is
     * unknown. */
    cyd_fmt_temp(-10, b, sizeof b);
    expect(b, "--", "any negative is unknown -- a live die is never sub-zero");
    cyd_fmt_temp(-60, b, sizeof b);
    expect(b, "--", "a wildly wrong value is unknown too");

    /* ---- fan --------------------------------------------------------- */
    printf("\n-- fan --\n");

    cyd_fmt_fan(1820, 55, b, sizeof b);
    expect(b, "1820 rpm (55%)", "both values known");

    cyd_fmt_fan(-1, 55, b, sizeof b);
    /* The two fail INDEPENDENTLY. The tach needs an external 10k pull-up that
     * was missing on this board until 2026-08-30; the duty is always known
     * because the FPGA sets it. Hiding a known duty behind an unknown tach
     * would report a working fan as an unknown one. */
    expect(b, "55%", "tach unreadable but duty is still known");

    cyd_fmt_fan(1820, -1, b, sizeof b);
    expect(b, "1820 rpm", "duty unknown, tach known");
    cyd_fmt_fan(-1, -1, b, sizeof b);
    expect(b, "--", "neither known");
    cyd_fmt_fan(0, 0, b, sizeof b);
    expect(b, "0 rpm (0%)", "a stopped fan is a reading, not unknown");
    cyd_fmt_fan(1820, 101, b, sizeof b);
    expect(b, "1820 rpm", "an out-of-range duty is rejected, not printed");

    /* ---- epoch countdown --------------------------------------------- */
    printf("\n-- epoch countdown --\n");

    /* Real numbers: the rollover this tree is now built for, seen from the
     * moment that build was prepared. */
    const uint32_t next = 1788480000u;   /* 2026-09-04 00:00 UTC */
    const uint32_t now  = 1788249620u;   /* 2026-09-01 08:00 UTC */

    cyd_fmt_epoch_left_at(next, now, b, sizeof b);
    expect(b, "2d 15h", "the real countdown to the 2026-09-04 rollover");

    cyd_fmt_epoch_left_at(next, next - 3600u * 15u - 60u * 30u, b, sizeof b);
    expect(b, "15h 30m", "under a day switches to hours and minutes");

    cyd_fmt_epoch_left_at(next, next - 60u * 42u, b, sizeof b);
    expect(b, "42m", "under an hour is minutes only");

    cyd_fmt_epoch_left_at(next, next, b, sizeof b);
    /* Not an error state: it means the bitstream is now mining rejects unless
     * it was rebuilt. The loudest thing this formatter can say. */
    expect(b, "ROLLED", "at the instant of rollover");

    cyd_fmt_epoch_left_at(next, next + 1u, b, sizeof b);
    expect(b, "ROLLED", "past the rollover");

    cyd_fmt_epoch_left_at(0, now, b, sizeof b);
    expect(b, "--", "never reported -> unknown, not a huge countdown");

    /* ---- buffers and null pointers ------------------------------------ */
    printf("\n-- hostile buffers --\n");

    /* A formatter that leaves a buffer untouched hands the drawing code
     * whatever was on the stack. Painting stack garbage over a hashrate is
     * worse than painting nothing, so every path must terminate the string. */
    {
        char tiny[4];
        memset(tiny, 'X', sizeof tiny);
        cyd_fmt_hashrate(68356137.0, tiny, sizeof tiny);
        checks++;
        if (tiny[sizeof tiny - 1] == '\0') {
            printf("  PASS  %-46s -> \"%s\"\n",
                   "a too-small buffer is still terminated", tiny);
        } else {
            printf("  FAIL  %-46s\n", "a too-small buffer is still terminated");
            errors++;
        }
    }

    /* Must not crash. No assertion beyond surviving the call. */
    cyd_fmt_hashrate(1.0, NULL, 16);
    cyd_fmt_temp(1, NULL, 16);
    cyd_fmt_fan(1, 1, NULL, 16);
    cyd_fmt_epoch_left_at(1, 0, NULL, 16);
    cyd_fmt_hashrate(1.0, b, 0);
    checks++;
    printf("  PASS  %-46s\n", "null buffer / zero length do not crash");

    printf("\n");
    if (errors == 0)
        printf("=== ALL %d CHECKS PASSED ===\n", checks);
    else
        printf("=== %d of %d CHECK(S) FAILED ===\n", errors, checks);
    return errors ? 1 : 0;
}
