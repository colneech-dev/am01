/*
 * test_pow_math.c -- unit test for PoW difficulty conversion, share work estimation,
 * target comparator, and JSON string escaping in miner_pipe_am01.c.
 */

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

static int errors = 0, checks = 0;

static void ok(int cond, const char *what)
{
    checks++;
    if (cond) { printf("  PASS  %s\n", what); }
    else      { printf("  FAIL  %s\n", what); errors++; }
}

/* -------------------------------------------------------------------------
 * Logic under test (from miner_pipe_am01.c)
 * ------------------------------------------------------------------------- */

static int target_met(const uint8_t hash[32], const uint8_t target[32])
{
    for (int i = 31; i >= 0; i--) {
        if (hash[i] < target[i]) return 1;
        if (hash[i] > target[i]) return 0;
    }
    return 1;
}

static double hash_to_difficulty(const uint8_t hash_le[32])
{
    double h = 0.0;
    int i;
    for (i = 31; i >= 24; i--)
        h = h * 256.0 + (double)hash_le[i];
    if (h < 1.0) {
        for (i = 23; i >= 16; i--)
            h = h * 256.0 + (double)hash_le[i];
        if (h < 1.0) return 1e15;
        return (double)0xFFFF0000U / h * 18446744073709551616.0;
    }
    return (double)0xFFFF0000U / h;
}

static double share_work(const uint8_t target[32])
{
    double tv = 0.0;
    for (int i = 31; i >= 0; i--) tv = tv * 256.0 + (double)target[i];
    if (tv <= 0.0) return 0.0;
    return ldexp(1.0, 256) / tv;
}

static const char *json_str(const char *in, char *out, size_t cap)
{
    size_t o = 0;
    if (!in) in = "";
    for (; *in && o + 7 < cap; in++) {
        unsigned char c = (unsigned char)*in;
        if (c == '"' || c == '\\') {
            out[o++] = '\\'; out[o++] = (char)c;
        } else if (c < 0x20) {
            o += (size_t)snprintf(out + o, cap - o, "\\u%04x", c);
        } else {
            out[o++] = (char)c;
        }
    }
    out[o] = '\0';
    return out;
}

/* -------------------------------------------------------------------------
 * Test cases
 * ------------------------------------------------------------------------- */

int main(void)
{
    printf("=== test_pow_math ===\n");

    /* 1. target_met comparator tests */
    printf("\n-- target_met --\n");
    {
        uint8_t target[32], hash_less[32], hash_more[32], hash_eq[32];
        memset(target, 0, sizeof target);
        memset(hash_less, 0, sizeof hash_less);
        memset(hash_more, 0, sizeof hash_more);
        memset(hash_eq, 0, sizeof hash_eq);

        target[31] = 0x00;
        target[30] = 0x10;   /* MSB target */

        hash_less[30] = 0x0F;
        hash_less[29] = 0xFF;

        hash_more[30] = 0x11;
        hash_more[29] = 0x00;

        hash_eq[30] = 0x10;

        ok(target_met(hash_less, target) == 1, "hash < target satisfies target");
        ok(target_met(hash_eq, target) == 1,   "hash == target satisfies target");
        ok(target_met(hash_more, target) == 0, "hash > target fails target");

        /* Tie-breaker on lower bytes */
        uint8_t t_low[32], h_low_less[32], h_low_more[32];
        memset(t_low, 0x55, sizeof t_low);
        memcpy(h_low_less, t_low, 32);
        memcpy(h_low_more, t_low, 32);

        h_low_less[0] = 0x54;
        h_low_more[0] = 0x56;

        ok(target_met(h_low_less, t_low) == 1, "lower byte tie-break (less) passes");
        ok(target_met(h_low_more, t_low) == 0, "lower byte tie-break (greater) fails");
    }

    /* 2. hash_to_difficulty calculations */
    printf("\n-- hash_to_difficulty --\n");
    {
        /* Diff-1 target: 0xFFFF << 208 (bytes 27 and 26 in 32-byte LE) */
        uint8_t diff1_hash[32];
        memset(diff1_hash, 0, sizeof diff1_hash);
        diff1_hash[27] = 0xFF;
        diff1_hash[26] = 0xFF;

        double d1 = hash_to_difficulty(diff1_hash);
        ok(fabs(d1 - 1.0) < 1e-4, "diff-1 standard target converts to ~1.0 difficulty");

        /* Half target -> double difficulty: 0x7FFF << 208 */
        uint8_t diff2_hash[32];
        memset(diff2_hash, 0, sizeof diff2_hash);
        diff2_hash[27] = 0x7F;
        diff2_hash[26] = 0xFF;

        double d2 = hash_to_difficulty(diff2_hash);
        ok(fabs(d2 - 2.0) < 1e-3, "half target converts to ~2.0 difficulty");
    }

    /* 3. share_work estimation */
    printf("\n-- share_work --\n");
    {
        uint8_t t_max[32];
        memset(t_max, 0xFF, sizeof t_max);
        double w_max = share_work(t_max);
        ok(fabs(w_max - 1.0) < 1e-3, "max target (2^256-1) yields ~1 hash of expected work");

        uint8_t t_half[32];
        memset(t_half, 0xFF, sizeof t_half);
        t_half[31] = 0x7F;
        double w_half = share_work(t_half);
        ok(fabs(w_half - 2.0) < 1e-2, "half target yields ~2 hashes of work");
    }

    /* 4. json_str escaping */
    printf("\n-- json_str --\n");
    {
        char out[128];

        json_str("simple_string", out, sizeof out);
        ok(strcmp(out, "simple_string") == 0, "simple string unchanged");

        json_str("worker\"with\"quotes", out, sizeof out);
        ok(strcmp(out, "worker\\\"with\\\"quotes") == 0, "quotes escaped with backslash");

        json_str("path\\with\\slashes", out, sizeof out);
        ok(strcmp(out, "path\\\\with\\\\slashes") == 0, "backslashes escaped");

        json_str("job\nwith\rnewlines", out, sizeof out);
        ok(strcmp(out, "job\\u000awith\\u000dnewlines") == 0, "control characters escaped as \\u00XX");

        char small[10];
        json_str("very_long_worker_name", small, sizeof small);
        ok(strlen(small) < sizeof(small), "small buffer safely truncated");
    }

    printf("\n=== %d/%d CHECKS PASSED ===\n", checks - errors, checks);
    return errors ? 1 : 0;
}
