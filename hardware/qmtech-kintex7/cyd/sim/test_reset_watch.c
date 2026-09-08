/*
 * test_reset_watch.c -- did the FPGA reset underneath us?
 *
 * Three edge cases decide whether this helps or hurts, and none of them can be
 * exercised through a mining loop:
 *
 *   the first observation must NOT fire   -- the counter is not cleared by
 *                                            reset, so at startup it holds
 *                                            history, not an event
 *   a failed read must NOT fire           -- a dropped read looks exactly like
 *                                            no reset, and acting on it would
 *                                            restart the job on a glitch
 *   the counter saturates at 15           -- it does not wrap
 *
 * Getting any of them wrong turns a diagnostic into a fault of its own: a
 * spurious "reset" redispatches the job and reopens the settle window.
 */

#include "reset_watch.h"

#include <stdio.h>
#include <stdint.h>

static int fails = 0;
static int checks = 0;

static void ok(int cond, const char *what)
{
    checks++;
    if (cond) {
        printf("  PASS  %s\n", what);
    } else {
        printf("  FAIL  %s\n", what);
        fails++;
    }
}

int main(void)
{
    printf("test_reset_watch: is an FPGA reset noticed, and only a real one?\n\n");

    /* ---- the baseline must be silent ---------------------------------- */
    {
        struct reset_watch w = RESET_WATCH_INIT;
        ok(reset_watch_step(&w, 1, 7) == 0,
           "the first observation establishes a baseline and does not fire");
        ok(reset_watch_step(&w, 1, 7) == 0, "an unchanged count stays silent");
    }

    /* ---- a real reset -------------------------------------------------- */
    {
        struct reset_watch w = RESET_WATCH_INIT;
        reset_watch_step(&w, 1, 3);
        ok(reset_watch_step(&w, 1, 4) == 1, "an increment fires once");
        ok(reset_watch_step(&w, 1, 4) == 0,
           "and only once -- it rebaselines rather than latching");
    }

    /* ---- several resets between polls ---------------------------------- */
    {
        struct reset_watch w = RESET_WATCH_INIT;
        reset_watch_step(&w, 1, 2);
        ok(reset_watch_step(&w, 1, 5) == 1,
           "three resets between polls still fire (one resync covers them)");
    }

    /* ---- a failed read is not a reset ---------------------------------- */
    {
        struct reset_watch w = RESET_WATCH_INIT;
        reset_watch_step(&w, 1, 9);
        ok(reset_watch_step(&w, 0, 0) == 0,
           "a failed read does NOT fire, whatever the stale value says");
        ok(reset_watch_step(&w, 1, 9) == 0,
           "and it did not corrupt the baseline either");
    }

    /* ---- saturation ---------------------------------------------------- */
    {
        struct reset_watch w = RESET_WATCH_INIT;
        reset_watch_step(&w, 1, 15);
        ok(reset_watch_step(&w, 1, 15) == 0,
           "at saturation further resets are invisible -- documented, not fixed");
    }

    /* ---- a DECREASE means reconfiguration, which also needs a resync ----
     * The counter only counts up, so a lower value means the FPGA was
     * reflashed or power-cycled and has never seen a job. Comparing with >
     * instead of != would miss it and leave the host dispatching into a core
     * that is not listening.
     */
    {
        struct reset_watch w = RESET_WATCH_INIT;
        reset_watch_step(&w, 1, 6);
        ok(reset_watch_step(&w, 1, 0) == 1,
           "a DECREASE fires too -- the part was reconfigured");
    }

    /* ---- it is a nibble ------------------------------------------------- */
    {
        struct reset_watch w = RESET_WATCH_INIT;
        reset_watch_step(&w, 1, 0x35);            /* 5 after masking */
        ok(reset_watch_step(&w, 1, 0x05) == 0,
           "bits above the nibble are ignored, not treated as a change");
    }

    /* ---- defensive ----------------------------------------------------- */
    ok(reset_watch_step(NULL, 1, 1) == 0, "a NULL watch returns 0, no crash");

    printf("\n");
    if (fails) {
        printf("=== %d of %d CHECKS FAILED ===\n", fails, checks);
        return 1;
    }
    printf("=== ALL %d CHECKS PASSED ===\n", checks);
    return 0;
}
