/*
 * share_recover.c -- see share_recover.h for why this exists.
 */

#include "share_recover.h"

int share_recover_pick(uint32_t reported, uint32_t *out_nonce,
                       share_valid_fn valid, void *ctx)
{
    if (!valid || !out_nonce)
        return SHARE_PICK_NONE;

    if (valid(reported, ctx)) {
        *out_nonce = reported;
        return SHARE_PICK_REPORTED;
    }

    /*
     * reported - 1, in 32-bit arithmetic, deliberately.
     *
     * At reported == 0 that wraps to 0xFFFFFFFF, and at 0x80000000 -- the base
     * of the second miner instance -- it lands on 0x7FFFFFFF, which the FIRST
     * instance also sweeps. Both are correct: the host recomputes the digest
     * and tests it against the pool's own target before submitting anything,
     * so a candidate from a neighbouring range either genuinely meets the
     * target or is rejected here. Whose half of the nonce space it came from
     * has no bearing on whether it is a valid share.
     *
     * It does mean the per-core counters can attribute one such recovery to
     * the wrong instance. That is a cosmetic skew in a diagnostic, at a rate
     * of about one nonce in 2^31, and not worth branching for.
     */
    uint32_t prev = reported - 1u;
    if (valid(prev, ctx)) {
        *out_nonce = prev;
        return SHARE_PICK_MINUS_ONE;
    }

    return SHARE_PICK_NONE;
}
