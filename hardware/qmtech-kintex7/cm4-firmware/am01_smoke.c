/*
 * am01_smoke.c -- does the FPGA compute the RIGHT hash?
 *
 * WHY THIS EXISTS. odo-miner reports every nonce that fails its software
 * re-check as "stale", which conflates two unrelated faults:
 *
 *   1. a genuinely stale nonce -- the job changed between find and drain
 *   2. the FPGA computing a DIFFERENT hash than the software oracle
 *
 * On 2026-08-30 the board ran 95 s against a live pool and reported
 * "found=10 shares=0 stale=10". Every nonce failed. That number cannot say
 * which of the two it was, and the two have completely different fixes: one is
 * a pool-churn race, the other means the bitstream is wrong and every share
 * this miner ever submits will be rejected.
 *
 * This test removes the ambiguity by construction. One fixed header, dispatched
 * once, never changed. There is no pool and no job switching, so staleness is
 * impossible -- any nonce that fails the oracle failed because the hardware and
 * the software disagree.
 *
 * Ported from odo-miner-cyclonev/hps/fpga_smoke_pipe.c. The one behavioural
 * change is deliberate: that version hardcodes SMOKE_EPOCH and refuses to run
 * unless the bitstream matches. Since the epoch rolls every 10 days, a constant
 * guarantees the test rots. This reads the epoch OUT of the bitstream and
 * builds the oracle from it, so the test and the hardware cannot disagree about
 * which OdoCrypt they are checking.
 *
 * Run as root, with odo-miner stopped -- the GPIO chip is opened exclusively.
 */

#define _POSIX_C_SOURCE 200809L

#include "miner_io_pipe.h"
#include "odocrypt_state.h"
#include "KeccakP-800-SnP.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <time.h>
#include <limits.h>

/* Target is tgt_msb * 2^248, i.e. the top byte of a 256-bit big-endian value.
 * 0x10 accepts about 1 hash in 16, which finds instantly and is the right
 * choice for a correctness check. Tighter values are what make the run long
 * enough to time, hence the argument. */
#define DEFAULT_TGT_MSB 0x10u
#define MAX_SAMPLES     16

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void sleep_us(long us)
{
    struct timespec ts = { us / 1000000L, (us % 1000000L) * 1000L };
    nanosleep(&ts, NULL);
}

/* Deterministic header, same generator as gen_vectors_pipe.c so the vectors
 * are comparable. Bytes 76..79 are the nonce field and are left zero -- the
 * FPGA sweeps them. */
static void build_header(uint32_t key, uint8_t h[80])
{
    uint32_t x = key ^ 0xDEADBEEFu;
    for (int i = 0; i < 80; i++) {
        x = x * 1664525u + 1013904223u;
        h[i] = (uint8_t)(x >> 24);
    }
    h[76] = h[77] = h[78] = h[79] = 0;
}

/* uint256 strict less-than over LE byte arrays (byte[31] is the MSB).
 * Same ordering as the RTL's cmp_256, deliberately. */
static int hash_lt(const uint8_t *a, const uint8_t *b)
{
    for (int i = 31; i >= 0; i--)
        if (a[i] != b[i]) return a[i] < b[i];
    return 0;
}

/* The oracle: odo_encrypt then Keccak-p[800,12], exactly as the RTL was
 * verified against. */
static void oracle_hash(const odo_epoch_state_t *st, const uint8_t header[80],
                        uint32_t nonce, uint8_t out[KeccakP800_stateSizeInBytes])
{
    memset(out, 0, KeccakP800_stateSizeInBytes);
    memcpy(out, header, 80);
    out[76] = (uint8_t)(nonce);
    out[77] = (uint8_t)(nonce >> 8);
    out[78] = (uint8_t)(nonce >> 16);
    out[79] = (uint8_t)(nonce >> 24);
    out[80] = 1;
    odo_encrypt(st, out, out);
    KeccakP800_Permute_12rounds(out);
}

/* Is the reported nonce merely OFFSET from the one that was hashed?
 *
 * Returns the offset K such that nonce+K satisfies the target, or INT_MIN if
 * none within +/-range. A consistent non-zero K across samples means the core
 * hashes correctly and miner.v's nonce_out counter is misaligned with the
 * pipeline -- a very different fault from a wrong cipher, and a much easier
 * one to fix. */
#define OFFSET_RANGE 4096
static long offset_search(const odo_epoch_state_t *st, const uint8_t header[80],
                          uint32_t nonce, const uint8_t target[32])
{
    uint8_t h[KeccakP800_stateSizeInBytes];
    for (long k = 1; k <= OFFSET_RANGE; k++) {
        oracle_hash(st, header, (uint32_t)(nonce + k), h);
        if (hash_lt(h, target)) return k;
        oracle_hash(st, header, (uint32_t)(nonce - k), h);
        if (hash_lt(h, target)) return -k;
    }
    return LONG_MIN;
}

int main(int argc, char **argv)
{
    unsigned tgt_msb = DEFAULT_TGT_MSB;
    int want = 4;

    if (argc > 1) tgt_msb = (unsigned)strtoul(argv[1], NULL, 0);
    if (argc > 2) want    = atoi(argv[2]);
    /* 4th arg: re-arm after each find (default ON). Without it the core halts
     * on the first solution and the run measures nothing. */
    int redispatch = (argc > 3) ? atoi(argv[3]) : 1;
    /* 5th arg: how many times to dispatch per arm attempt.
     *
     * target_word_cnt_h in the wrapper is reg [3:0] but is compared to 7,
     * so it wraps at 16 rather than 8 and nothing resets it between jobs.
     * That means start_hash is armed on every OTHER dispatch. Dispatching
     * twice covers both parities. If finds become reliable at 2 and are
     * erratic at 1, that counter width is the bug. */
    int arm_reps = (argc > 4) ? atoi(argv[4]) : 1;
    /* 6th arg: dispatch a DIFFERENT header on every re-arm, instead of
     * re-arming the same one repeatedly.
     *
     * 2026-08-31: real pool mining showed found=861913 shares=1 stale=861912
     * over 38 min on 0x0109 -- near-total staleness, even though this same
     * tool with cycle_headers=0 measured 15/16 pass on the identical
     * bitstream moments earlier. The one thing the default mode never
     * exercises is a header CHANGE between dispatches: redispatch=1 only
     * ever re-arms the SAME header/target, but real mining also redispatches
     * on every new pool job (every 5-10s) with genuinely different content,
     * via the same miner_io_pipe_dispatch() call. This mode reproduces that:
     * disp_header is what was actually in flight when a result is drained
     * (validated against, same disp/cur split as miner_pipe_am01.c), and a
     * NEW header is only committed as disp_header for the FOLLOWING drain,
     * never the one just validated. */
    int cycle_headers = (argc > 5) ? atoi(argv[5]) : 0;
    if (tgt_msb == 0 || tgt_msb > 0xFF) {
        fprintf(stderr, "usage: %s [target_msb 1..255] [samples] [redispatch] "
                        "[arm_reps] [cycle_headers]\n", argv[0]);
        return 2;
    }
    if (want < 1) want = 1;
    if (want > MAX_SAMPLES) want = MAX_SAMPLES;

    if (miner_io_pipe_init() != 0) {
        fprintf(stderr, "am01_smoke: miner_io_pipe_init failed "
                        "(run as root, and stop odo-miner first)\n");
        return 1;
    }

    uint32_t seed = miner_io_pipe_seed();
    uint32_t ver  = miner_io_pipe_version();
    printf("FPGA version 0x%04x, bitstream epoch %u\n", ver, seed);

    /* v2.0+ runs a free-running core: it never halts on a find, so there is
     * nothing to re-arm, and a dispatch is a COMMIT that restarts the settle
     * window. Re-dispatching after every find would keep that window open and
     * suppress most finds -- the opposite of what this test wants. Default it
     * off there unless the caller explicitly asked for it. */
    if ((ver >> 16) >= 2u && argc <= 3) {
        redispatch = 0;
        printf("free-running core (v%u.%u): re-dispatch off by default\n",
               ver >> 16, ver & 0xFFFFu);
    }

    if (seed == 0 || seed == 0xFFFFFFFFu) {
        printf("FAIL: implausible epoch read back -- the bus is not returning\n"
               "      real register data, so nothing below would mean anything.\n");
        miner_io_pipe_shutdown();
        return 1;
    }

    /* The oracle is built from the epoch the HARDWARE reports. If the two ever
     * disagreed, every comparison below would be meaningless -- and that is
     * precisely the bug this test exists to catch, so it must not be possible
     * to introduce it here. */
    odo_epoch_state_t st;
    odo_epoch_generate(&st, seed);

    uint8_t header[80];
    build_header(seed, header);
    /* disp_header is the header actually armed for whatever result is next
     * drained -- same split as miner_pipe_am01.c's disp/cur. Only relevant
     * when cycle_headers is set; otherwise it just tracks `header`. */
    uint8_t disp_header[80];
    memcpy(disp_header, header, 80);
    uint32_t next_key = seed;

    uint8_t target[32];
    memset(target, 0, sizeof(target));
    target[31] = (uint8_t)tgt_msb;

    printf("dispatching one fixed job, target = 0x%02x * 2^248 "
           "(~1 hash in %.1f)\n", tgt_msb, 256.0 / (double)tgt_msb);
    printf("no pool, no job switching -- a failure here CANNOT be staleness\n\n");

    double t0 = now_s();
    for (int r = 1; r < arm_reps; r++)
        miner_io_pipe_dispatch(header, target);
    if (miner_io_pipe_dispatch(header, target) != 0) {
        printf("FAIL: dispatch returned an error\n");
        miner_io_pipe_shutdown();
        return 1;
    }

    int pass = 0, fail = 0, got = 0;
    long off_first = LONG_MIN;
    int  off_found = 0, off_consistent = 1;
    double t_first = 0.0;

    while (got < want) {
        uint32_t nonce = 0;
        int rc = -1;

        /* ~10 s per sample. A tight target legitimately takes a while; a wrong
         * core does not take longer, it just fails, so a timeout here means
         * "not finding", not "computing badly". */
        for (int i = 0; i < 100000; i++) {
            rc = miner_io_pipe_poll(&nonce);
            if (rc == 0) break;
            if (rc < 0) {
                printf("FAIL: poll I/O error\n");
                miner_io_pipe_shutdown();
                return 1;
            }
            sleep_us(100);
        }
        if (rc != 0) {
            printf("no further nonce within timeout after %d sample(s)\n", got);
            break;
        }

        double t = now_s();
        if (got == 0) t_first = t - t0;
        got++;

        /* Validate against disp_header -- the header that was ACTUALLY armed
         * when this nonce was computed -- before touching it for the next
         * dispatch. Same ordering miner_pipe_am01.c uses and for the same
         * reason: checking against a header that has already moved on is a
         * guaranteed false "stale", not a real one. */
        uint8_t h[KeccakP800_stateSizeInBytes];
        oracle_hash(&st, disp_header, nonce, h);
        int ok = hash_lt(h, target);
        if (ok) pass++; else fail++;

        printf("  nonce 0x%08x  hash MSB %02x%02x%02x%02x  %s\n",
               nonce, h[31], h[30], h[29], h[28],
               ok ? "PASS" : "FAIL <-- hardware and oracle disagree");

        if (!ok) {
            /* Distinguish a wrong CIPHER from a wrong REPORTED NONCE. */
            long k = offset_search(&st, disp_header, nonce, target);
            if (k != LONG_MIN) {
                printf("        -> but nonce%+ld DOES satisfy the target.\n", k);
                printf("           The core hashed correctly and reported the\n");
                printf("           WRONG NONCE -- miner.v's nonce_out counter is\n");
                printf("           misaligned with the pipeline by %ld.\n", k);
                if (off_first == LONG_MIN) off_first = k;
                else if (off_first != k)   off_consistent = 0;
                off_found++;
            } else {
                printf("        -> no nonce within +/-%d satisfies it either.\n",
                       OFFSET_RANGE);
                printf("           Not a simple offset; the hash itself differs.\n");
            }
        }

        /* RE-ARM. host_break_sm raises sha_host_break on ticket2moon and the
         * wrapper clears start_hash_h on that, so the core HALTS on every
         * solution and waits for the host to re-arm it. Re-writing the 8
         * target words is what re-arms it -- the 8th sets start_hash.
         *
         * odo-miner does not do this: it dispatches only when a NEW job
         * arrives, so the FPGA idles between jobs. If re-dispatching turns one
         * find into a stream, that is the whole explanation for the observed
         * "found=10 in 95 s".
         *
         * If cycle_headers, this is also where a genuinely NEW job's content
         * gets built and dispatched -- disp_header only becomes the new
         * content AFTER the dispatch call, so the NEXT drained result is what
         * gets validated against it, never this one. */
        if (redispatch) {
            if (cycle_headers) {
                next_key++;
                build_header(next_key, header);
            }
            for (int r = 1; r < arm_reps; r++)
                miner_io_pipe_dispatch(header, target);
            if (miner_io_pipe_dispatch(header, target) != 0) {
                printf("FAIL: re-dispatch failed\n");
                break;
            }
            memcpy(disp_header, header, 80);
        }
    }

    double elapsed = now_s() - t0;
    printf("\n%d found, %d pass, %d fail, in %.2f s (first find %.3f s)\n",
           got, pass, fail, elapsed, t_first);

    if (got > 0) {
        /* Expected hashes per find is 256/tgt_msb; finds per second times that
         * is an effective hashrate. Rough -- it ignores the dispatch settle
         * window and the polling granularity -- but it is measured, and the
         * only hashrate figure on this project so far came from static timing. */
        double per_find = 256.0 / (double)tgt_msb;
        double rate = ((double)got / elapsed) * per_find;
        printf("effective hashrate ~ %.2f MH/s (measured, not from timing)\n",
               rate / 1e6);
    }

    miner_io_pipe_shutdown();

    if (got == 0) {
        printf("\nVERDICT: the core found nothing. Not a hash-correctness\n"
               "         result -- look at whether it is running at all.\n");
        return 1;
    }
    if (fail == 0) {
        printf("\nVERDICT: PASS -- the FPGA and the software oracle agree.\n"
               "         Hashes are correct, so the pool rejections are a\n"
               "         job-churn/staleness problem, not a bad bitstream.\n");
        return 0;
    }
    if (off_found > 0 && off_consistent && off_first != LONG_MIN) {
        printf("\nVERDICT: NONCE OFFSET -- every failing nonce is out by exactly\n"
               "         %+ld. The cipher is correct (tb_encrypt_oracle proves\n"
               "         encrypt.v bit-exact); what is wrong is which nonce the\n"
               "         hardware REPORTS for a given result. Look at nonce_out\n"
               "         and the cou_deltanonce == 6'h33 warm-up in miner.v --\n"
               "         204 cycles must equal the real pipeline latency.\n",
               off_first);
        miner_io_pipe_shutdown();
        return 1;
    }
    if (pass == 0) {
        printf("\nVERDICT: FAIL -- every nonce disagrees with the oracle.\n"
               "         The bitstream computes the wrong hash. Regenerate\n"
               "         encrypt.v and rebuild; see docs/CODE-REVIEW-2026-08-30.md\n"
               "         finding #1 and tools/check-epoch.sh.\n");
        return 1;
    }
    printf("\nVERDICT: MIXED -- %d of %d disagree. Not a clean either/or;\n"
           "         suspect marginal timing rather than a wrong core.\n", fail, got);
    return 1;
}
