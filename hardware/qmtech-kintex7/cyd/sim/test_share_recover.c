/*
 * test_share_recover.c -- the off-by-one recovery, which decides whether real
 * work is submitted or thrown away.
 *
 * This logic lived inline in main() until 2026-09-08 and had no test. It was
 * written in response to a measured hardware fault -- at 225 MHz the fabric
 * labels ~36% of finds with a nonce one too high -- and it is the difference
 * between 44 MH/s and 99 MH/s on such a build. Untested code in that position
 * is not acceptable, and the mining loop is not a place anything can be
 * exercised deliberately.
 *
 * The validity callback keeps the cipher out of it: these tests know exactly
 * which nonces "work", so every branch is reachable.
 */

#include "share_recover.h"

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

/* A stub target: only the nonces listed in ctx are "valid". */
struct oracle {
    uint32_t good[4];
    int      n;
    int      calls;
};

static int stub_valid(uint32_t nonce, void *ctx)
{
    struct oracle *o = ctx;
    o->calls++;
    for (int i = 0; i < o->n; i++)
        if (o->good[i] == nonce)
            return 1;
    return 0;
}

int main(void)
{
    printf("test_share_recover: does the off-by-one retry pick the right nonce?\n\n");

    /* ---- the healthy case: the reported nonce is the right one --------- */
    {
        struct oracle o = { { 0x1000 }, 1, 0 };
        uint32_t use = 0xDEADBEEF;
        int r = share_recover_pick(0x1000, &use, stub_valid, &o);
        ok(r == SHARE_PICK_REPORTED, "a valid reported nonce is taken as-is");
        ok(use == 0x1000, "and it is the nonce handed back");
        ok(o.calls == 1, "the predecessor is NOT probed when the report is good");
    }

    /* ---- the fault: the digest belongs to reported-1 ------------------- */
    {
        struct oracle o = { { 0x0FFF }, 1, 0 };
        uint32_t use = 0;
        int r = share_recover_pick(0x1000, &use, stub_valid, &o);
        ok(r == SHARE_PICK_MINUS_ONE, "a mislabelled find is recovered at -1");
        ok(use == 0x0FFF, "and the PREDECESSOR is what gets submitted");
        ok(o.calls == 2, "which costs exactly one extra evaluation");
    }

    /* ---- a real stale: neither works ---------------------------------- */
    {
        struct oracle o = { { 0x2000 }, 1, 0 };
        uint32_t use = 0xAAAAAAAA;
        int r = share_recover_pick(0x1000, &use, stub_valid, &o);
        ok(r == SHARE_PICK_NONE, "neither candidate valid -> a genuine stale");
        ok(use == 0xAAAAAAAA, "and out_nonce is left alone");
    }

    /* ---- ORDER. If both are valid the reported one must win. ----------
     * Not a curiosity: it is what makes the recovery counter an alarm. A
     * bitstream that has stopped mislabelling must show ZERO recoveries, not
     * a mixture, or the number cannot be used to tell the two apart -- which
     * is exactly what validate-bitstream.sh does with it.
     */
    {
        struct oracle o = { { 0x1000, 0x0FFF }, 2, 0 };
        uint32_t use = 0;
        int r = share_recover_pick(0x1000, &use, stub_valid, &o);
        ok(r == SHARE_PICK_REPORTED, "with both valid, the reported nonce wins");
        ok(use == 0x1000, "so a healthy build records no recovery");
    }

    /* ---- wraparound at zero ------------------------------------------- */
    {
        struct oracle o = { { 0xFFFFFFFFu }, 1, 0 };
        uint32_t use = 0;
        int r = share_recover_pick(0x00000000u, &use, stub_valid, &o);
        ok(r == SHARE_PICK_MINUS_ONE, "nonce 0 probes 0xFFFFFFFF, not -1 signed");
        ok(use == 0xFFFFFFFFu, "and submits it");
    }

    /* ---- the instance boundary ----------------------------------------
     * The two miners start at 0x00000000 and 0x80000000, so a recovery at the
     * second's base lands in the first's half. That is fine and deliberate:
     * the host has already recomputed the digest against the pool's own
     * target, so where the candidate came from does not bear on whether it is
     * a valid share. Pinned here so nobody "fixes" it later.
     */
    {
        struct oracle o = { { 0x7FFFFFFFu }, 1, 0 };
        uint32_t use = 0;
        int r = share_recover_pick(0x80000000u, &use, stub_valid, &o);
        ok(r == SHARE_PICK_MINUS_ONE,
           "a recovery across the instance boundary is still accepted");
        ok(use == 0x7FFFFFFFu, "0x80000000 -> 0x7FFFFFFF");
    }

    /* ---- defensive: no callback, no crash ----------------------------- */
    {
        uint32_t use = 0;
        ok(share_recover_pick(1, &use, NULL, NULL) == SHARE_PICK_NONE,
           "a NULL validator returns NONE rather than dereferencing it");
        ok(share_recover_pick(1, NULL, stub_valid, NULL) == SHARE_PICK_NONE,
           "so does a NULL out_nonce");
    }

    printf("\n");
    if (fails) {
        printf("=== %d of %d CHECKS FAILED ===\n", fails, checks);
        return 1;
    }
    printf("=== ALL %d CHECKS PASSED ===\n", checks);
    return 0;
}
