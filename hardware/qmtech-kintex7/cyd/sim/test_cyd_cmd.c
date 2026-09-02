/*
 * test_cyd_cmd.c -- what a line from the panel is allowed to mean.
 *
 *   cc -Wall -Wextra -I../host -o /tmp/t test_cyd_cmd.c ../host/cyd_cmd.c \
 *      && /tmp/t
 *
 * This channel can REBOOT THE MINER and rewrite /boot/am01-miner.conf, which
 * survives a reflash. The trust boundary is physical -- four wires inside a
 * case -- so this is not defending against an attacker. It is defending
 * against a corrupted line, a half-received line, and a firmware bug at the
 * far end, all of which are ordinary on a serial link and any of which could
 * otherwise leave the miner booting to a pool that does not exist.
 *
 * The bias throughout is REJECT RATHER THAN GUESS. A command the daemon half
 * understands is worse than one it ignores, because the panel will resend.
 */

#include "cyd_cmd.h"

#include <stdio.h>
#include <string.h>

static int errors = 0, checks = 0;

static void ok(int cond, const char *what)
{
    checks++;
    if (cond) printf("  PASS  %s\n", what);
    else    { printf("  FAIL  %s\n", what); errors++; }
}

static cyd_cmd_kind_t k(const char *line, cyd_cmd_t *c)
{
    return cyd_cmd_parse(line, c);
}

int main(void)
{
    cyd_cmd_t c;
    printf("=== test_cyd_cmd ===\n");

    /* ---- the happy path ---------------------------------------------- */
    printf("\n-- valid commands --\n");

    ok(k("PING", &c) == CYD_CMD_KIND_PING,                       "PING");
    ok(k("CMD reset_stats", &c) == CYD_CMD_KIND_RESET_STATS,     "reset_stats");
    ok(k("CMD reboot", &c) == CYD_CMD_KIND_REBOOT,               "reboot");

    ok(k("CMD fan_boost 1", &c) == CYD_CMD_KIND_FAN_BOOST && c.fan_on == 1,
       "fan_boost 1");
    ok(k("CMD fan_boost 0", &c) == CYD_CMD_KIND_FAN_BOOST && c.fan_on == 0,
       "fan_boost 0");

    ok(k("CMD set_pool 192.168.1.100 5103 DTGwfAPbxQaKViGpoy8XfVguMPj5sGxTdS.Odo02 x", &c)
           == CYD_CMD_KIND_SET_POOL
       && strcmp(c.host, "192.168.1.100") == 0
       && c.port == 5103
       && strcmp(c.worker, "DTGwfAPbxQaKViGpoy8XfVguMPj5sGxTdS.Odo02") == 0
       && strcmp(c.pass, "x") == 0,
       "set_pool with a real wallet-style worker");

    /* Trailing CR must not break anything -- the link is line-oriented text
     * and the far end may or may not send CRLF. */
    ok(k("CMD reboot\r\n", &c) == CYD_CMD_KIND_REBOOT, "trailing CRLF tolerated");
    ok(k("CMD  reboot", &c) == CYD_CMD_KIND_REBOOT,    "extra spaces tolerated");

    /* ---- rejection ---------------------------------------------------- */
    printf("\n-- rejected, and this is the point --\n");

    ok(k("", &c) == CYD_CMD_KIND_NONE,               "empty line");
    ok(k("garbage", &c) == CYD_CMD_KIND_NONE,        "unknown text");
    ok(k(NULL, &c) == CYD_CMD_KIND_NONE,             "NULL line does not crash");
    ok(k("CMD reboot", NULL) == CYD_CMD_KIND_NONE,   "NULL out does not crash");
    ok(k("CMD", &c) == CYD_CMD_KIND_NONE,            "prefix with no verb");
    ok(k("CMD wibble", &c) == CYD_CMD_KIND_NONE,     "unknown verb");

    /* EXTRA ARGUMENTS ARE A REJECTION. "CMD reboot now" is not a reboot with
     * a stray word on the end -- it is a line we do not understand, and
     * acting on the part we recognise is the exact failure mode this file
     * exists to prevent. */
    ok(k("CMD reboot now", &c) == CYD_CMD_KIND_NONE,
       "reboot with a trailing argument is REJECTED, not obeyed");
    ok(k("CMD reset_stats please", &c) == CYD_CMD_KIND_NONE,
       "reset_stats with a trailing argument is rejected");
    ok(k("CMD fan_boost 1 1", &c) == CYD_CMD_KIND_NONE,
       "fan_boost with two arguments is rejected");

    /* fan_boost takes exactly 0 or 1. atoi() would read "on" as 0 and turn a
     * boost request into a cancel -- silently, and in the direction that
     * makes the board hotter. */
    ok(k("CMD fan_boost on", &c) == CYD_CMD_KIND_NONE,  "fan_boost 'on' rejected");
    ok(k("CMD fan_boost 2", &c) == CYD_CMD_KIND_NONE,   "fan_boost 2 rejected");
    ok(k("CMD fan_boost -1", &c) == CYD_CMD_KIND_NONE,  "fan_boost -1 rejected");
    ok(k("CMD fan_boost", &c) == CYD_CMD_KIND_NONE,     "fan_boost with no arg");

    /* ---- set_pool, the one that persists ------------------------------ */
    printf("\n-- set_pool: it writes a file that survives a reflash --\n");

    ok(k("CMD set_pool host 5103 worker", &c) == CYD_CMD_KIND_NONE,
       "too few fields rejected");
    ok(k("CMD set_pool host 5103 worker pass extra", &c) == CYD_CMD_KIND_NONE,
       "too many fields rejected");
    ok(k("CMD set_pool host 0 worker pass", &c) == CYD_CMD_KIND_NONE,
       "port 0 rejected");
    ok(k("CMD set_pool host 65536 worker pass", &c) == CYD_CMD_KIND_NONE,
       "port 65536 rejected");
    ok(k("CMD set_pool host -1 worker pass", &c) == CYD_CMD_KIND_NONE,
       "negative port rejected");

    /* atoi("5103x") is 5103. A pool port that silently drops characters is a
     * miner that connects nowhere, and nothing on the panel would say why. */
    ok(k("CMD set_pool host 5103x worker pass", &c) == CYD_CMD_KIND_NONE,
       "port with trailing junk REJECTED, not silently truncated to 5103");
    ok(k("CMD set_pool host abc worker pass", &c) == CYD_CMD_KIND_NONE,
       "non-numeric port rejected");

    /* Over-length must reject, not truncate. A host shortened from
     * "pool.example.com" to "pool.exampl" is a miner mining to nowhere that
     * looks like a network fault. */
    {
        char big[512];
        char host[200];
        memset(host, 'a', sizeof host - 1);
        host[sizeof host - 1] = '\0';
        snprintf(big, sizeof big, "CMD set_pool %s 5103 w p", host);
        ok(k(big, &c) == CYD_CMD_KIND_NONE,
           "an over-long host is REJECTED, not truncated");
    }

    /* On any rejection the output must be left clean, so a caller that
     * ignores the return value cannot act on a stale host from a previous
     * successful parse. */
    k("CMD set_pool goodhost 5103 w p", &c);
    k("CMD set_pool badhost notaport w p", &c);
    ok(c.kind == CYD_CMD_KIND_NONE && c.host[0] == '\0' && c.port == 0,
       "a rejected parse CLEARS the output, leaving no stale fields");

    printf("\n");
    if (errors == 0) printf("=== ALL %d CHECKS PASSED ===\n", checks);
    else             printf("=== %d of %d CHECK(S) FAILED ===\n", errors, checks);
    return errors ? 1 : 0;
}
