/*
 * test_cyd_status_parse.c -- the parser, against the miner's REAL output.
 *
 *   cc -Wall -Wextra -I../firmware/include -I../host \
 *      -o /tmp/t test_cyd_status_parse.c ../firmware/src/cyd_status_parse.c \
 *      && /tmp/t
 *
 * The fixture below is a verbatim capture of /run/odod/status.json from the
 * board on 2026-09-01, not a hand-written approximation. That distinction is
 * the whole value: a fixture I invented would agree with whatever I assumed
 * the miner emits, and the failure this guards against is precisely my
 * assumption being wrong.
 *
 * Note it contains fan_duty_pct: -1 -- a real sentinel caught in the wild,
 * which is exactly the kind of thing a tidied-up fixture loses.
 */

#include "cyd_status_parse.h"

#include <stdio.h>
#include <string.h>
#include <math.h>

static int errors = 0, checks = 0;

static void ok(int cond, const char *what)
{
    checks++;
    if (cond) printf("  PASS  %s\n", what);
    else    { printf("  FAIL  %s\n", what); errors++; }
}

/* Captured from the board, byte for byte. */
static const char REAL[] =
"{\n"
"  \"pool\": \"10.0.0.2:5103\",\n"
"  \"connected\": true,\n"
"  \"core\": \"pipelined\",\n"
"  \"job_id\": \"0001a101\",\n"
"  \"epoch\": 1787616000,\n"
"  \"bitstream_epoch\": 1787616000,\n"
"  \"epoch_interval\": 864000,\n"
"  \"epoch_next\": 1788480000,\n"
"  \"hashrate\": 63132233.0,\n"
"  \"hashes_total\": 0,\n"
"  \"shares_found\": 3417,\n"
"  \"shares_submitted\": 3408,\n"
"  \"shares_accepted\": 3406,\n"
"  \"shares_rejected\": 2,\n"
"  \"last_share\": 1788278379,\n"
"  \"best_diff_session\": 267.579,\n"
"  \"best_diff_alltime\": 267.579,\n"
"  \"blocks_found\": 0,\n"
"  \"last_block\": 0,\n"
"  \"temp_c\": 55,\n"
"  \"vccint\": 0.979,\n"
"  \"vccaux\": 1.808,\n"
"  \"fan_duty_pct\": -1,\n"
"  \"fan_rpm\": 3030,\n"
"  \"backend\": \"gpio\",\n"
"  \"pool_slot\": 1,\n"
"  \"pool_count\": 1,\n"
"  \"uptime\": 27236,\n"
"  \"updated\": 1788278871\n"
"}\n";

int main(void)
{
    cyd_status_t st;
    printf("=== test_cyd_status_parse ===\n");

    printf("\n-- the miner's real status.json --\n");
    memset(&st, 0, sizeof st);
    ok(cyd_status_parse(REAL, &st), "parses");

    ok(fabs(st.hashrate - 63132233.0) < 1.0, "hashrate 63132233");
    ok(st.connected,                          "connected true");
    ok(strcmp(st.pool, "10.0.0.2:5103") == 0, "pool string");
    ok(strcmp(st.job_id, "0001a101") == 0,    "job_id");
    ok(strcmp(st.backend, "gpio") == 0,       "backend");
    ok(strcmp(st.core, "pipelined") == 0,     "core");

    ok(st.shares_found == 3417,    "shares_found 3417");
    ok(st.shares_accepted == 3406, "shares_accepted 3406");
    ok(st.shares_rejected == 2,    "shares_rejected 2");
    ok(st.blocks_found == 0,       "blocks_found 0");

    ok(fabs(st.best_diff_session - 267.579) < 0.001, "best_diff_session");
    ok(st.uptime == 27236,      "uptime");

    /* `updated` is the miner's wall clock and the ONLY sound "now" for the
     * epoch countdown. The first version used epoch + uptime, which is an
     * arbitrary instant -- epoch is when the OdoCrypt epoch began, not when
     * the miner started. Here that sum would be 1787643236, five days adrift
     * of the real 1788278871, and the countdown would look plausible. */
    ok(st.updated == 1788278871, "updated (the wall clock) is parsed");
    ok(st.updated != st.epoch + st.uptime,
       "and differs from epoch+uptime, which was the bug");
    ok(st.temp_c == 55,         "temp_c 55");
    /* THE ESCAPES miner_pipe_am01.c ACTUALLY EMITS.
     *
     * json_str() escapes quote, backslash and every control character --
     * the last as a six-character \\uXXXX. get_str() used to skip the
     * backslash and copy the rest, so one of those rendered on the panel
     * as the literal text u0009. Quote and backslash came out right by
     * the same accident. */
    {
        cyd_status_t e;
        memset(&e, 0, sizeof e);
        char js[256];
        snprintf(js, sizeof js,
                 "{\"hashrate\": 1.0, \"job_id\": \"a\\u0009b\", "
                 "\"worker\": \"q\\\"r\"}");
        ok(cyd_status_parse(js, &e), "a status carrying escapes parses");
        ok(!strcmp(e.job_id, "a?b"),
           "a \\u0009 control escape decodes, not 'u0009' verbatim");
        ok(!strcmp(e.worker, "q\"r"),
           "and an escaped quote still comes through as one quote");
    }


    /* The rails. VCCINT is the one that matters: no current sense exists on
     * this board, so a change in the core rail is the only signal available
     * that the FPGA is being pushed harder than the MP8712 likes. */
    ok(st.vccint > 0.978 && st.vccint < 0.980, "vccint parsed as 0.979");
    ok(st.vccaux > 1.807 && st.vccaux < 1.809, "vccaux parsed as 1.808");
    /* ABSENT is not the same as ZERO. An older odo-miner omits the key
     * entirely and must leave the -1 sentinel, so the panel can show "--"
     * rather than a confident 0.000V that looks like a dead rail. */
    ok(st.vccbram < 0, "a rail the miner did not report stays at the -1 sentinel");
    ok(st.fan_rpm == 3030,      "fan_rpm 3030");

    /* THE SENTINEL. -1 must survive as -1 so cyd_fmt_fan renders "--".
     * Clamping it to 0 here would draw "0%" -- a stopped fan, which is both
     * untrue and alarming. */
    ok(st.fan_duty_pct == -1,
       "fan_duty_pct -1 survives as -1, NOT clamped to 0");

    /* ---- the substring trap ------------------------------------------ */
    printf("\n-- keys that contain other keys --\n");

    /* "epoch" is a substring of BOTH "epoch_next" and "bitstream_epoch", and
     * all three hold plausible-looking unix timestamps. A scanner matching a
     * bare substring returns the wrong one and NOTHING looks odd -- the
     * countdown is just silently wrong. This is the check that earns the
     * quoted-key matching in find_val(). */
    ok(st.epoch == 1787616000,
       "epoch is 1787616000, not epoch_next's or bitstream_epoch's value");
    ok(st.epoch_next == 1788480000,      "epoch_next 1788480000");
    ok(st.bitstream_epoch == 1787616000, "bitstream_epoch 1787616000");
    ok(st.epoch != st.epoch_next,        "and the two are distinct");

    /* ---- robustness --------------------------------------------------- */
    printf("\n-- malformed and hostile input --\n");

    memset(&st, 0, sizeof st);
    ok(!cyd_status_parse("", &st),            "empty string rejected");
    ok(!cyd_status_parse("not json", &st),    "garbage rejected");
    ok(!cyd_status_parse("{\"pool\":\"x\"}", &st),
       "an object with no hashrate is rejected, not half-applied");
    ok(!cyd_status_parse(NULL, &st),          "NULL json does not crash");
    ok(!cyd_status_parse(REAL, NULL),         "NULL out does not crash");

    /* A truncated line must leave earlier fields intact rather than zeroing
     * them: the panel keeps one status across updates, and a half-line
     * should degrade it, not blank it. */
    memset(&st, 0, sizeof st);
    cyd_status_parse(REAL, &st);
    uint64_t keep = st.shares_accepted;
    cyd_status_parse("{\"hashrate\": 1234.0}", &st);
    ok(fabs(st.hashrate - 1234.0) < 0.1, "a short line updates what it has");
    ok(st.shares_accepted == keep,
       "and LEAVES the rest alone rather than zeroing it");

    /* Over-long strings must truncate, not overrun. `pool` is host:port from
     * a config file, so its length is not ours to assume. */
    {
        char big[512];
        snprintf(big, sizeof big,
                 "{\"hashrate\":1.0,\"pool\":\"%s\"}",
                 "0123456789012345678901234567890123456789"
                 "0123456789012345678901234567890123456789");
        memset(&st, 0, sizeof st);
        cyd_status_parse(big, &st);
        ok(strlen(st.pool) < sizeof st.pool, "an over-long pool truncates safely");
    }

    printf("\n");
    if (errors == 0) printf("=== ALL %d CHECKS PASSED ===\n", checks);
    else             printf("=== %d of %d CHECK(S) FAILED ===\n", errors, checks);
    return errors ? 1 : 0;
}
