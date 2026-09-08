/*
 * share_recover.h -- pick the nonce that actually yields a share.
 *
 * WHY THIS IS A SEPARATE FILE
 *
 * Measured on hardware 2026-09-07: at 225 MHz the fabric labels ~36% of its
 * finds with a nonce ONE TOO HIGH. The digest is right, the label is wrong --
 * `nonce`'s clock enable was (has_res & res) while nonce_out's was has_res
 * alone, so a missed setup window let nonce load the already-incremented
 * value. VERSION 0x020A gives them the same enable, and the host still checks,
 * because the host is where a wrong answer becomes a lost share.
 *
 * This logic lived inline in main() and could not be tested. It decides
 * whether real work is submitted or thrown away, which is exactly the kind of
 * thing that should not be reachable only through a mining loop with a pool
 * attached.
 *
 * The validity callback keeps the cipher out of the test: a unit test supplies
 * a stub, the miner supplies compute_pow + target_met.
 */

#ifndef SHARE_RECOVER_H
#define SHARE_RECOVER_H

#include <stdint.h>

/* Return non-zero if `nonce` yields a hash meeting the current job's target. */
typedef int (*share_valid_fn)(uint32_t nonce, void *ctx);

enum {
    SHARE_PICK_NONE      = 0,   /* neither candidate works -- a real stale */
    SHARE_PICK_REPORTED  = 1,   /* the nonce the fabric reported            */
    SHARE_PICK_MINUS_ONE = 2    /* reported - 1: the off-by-one, recovered  */
};

/*
 * Try the reported nonce, then its predecessor.
 *
 * ORDER MATTERS AND IS NOT ARBITRARY. The reported nonce is tried first so a
 * healthy bitstream never pays for the fault, and so a build that has stopped
 * mislabelling shows zero recoveries rather than a mixture -- which is what
 * makes the recovery counter usable as an alarm.
 *
 * ONLY -1 is probed. That is all the measurement supports: every other offset
 * in -4..+4 came back at exactly zero across 1085 mislabelled finds. Widening
 * the search would invent shares from a fault nobody has characterised.
 *
 * On success *out_nonce carries the nonce to submit. Untouched otherwise.
 */
int share_recover_pick(uint32_t reported, uint32_t *out_nonce,
                       share_valid_fn valid, void *ctx);

#endif /* SHARE_RECOVER_H */
