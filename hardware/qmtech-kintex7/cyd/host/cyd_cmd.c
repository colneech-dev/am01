/*
 * cyd_cmd.c -- see cyd_cmd.h for why this is separate from anything that acts.
 */

#include "cyd_cmd.h"
#include "cyd_proto.h"

#include <stdlib.h>
#include <stdio.h>
#include <string.h>

/* Copy one whitespace-delimited token. Returns the start of the next, or NULL
 * if there was no token or it did not fit.
 *
 * NOT FITTING IS A FAILURE, not a truncation. A pool host silently shortened
 * from "pool.example.com" to "pool.exampl" is a miner that boots and mines to
 * nowhere, which looks like a network fault for as long as it takes someone
 * to read the config file. */
static const char *token(const char *p, char *out, size_t n)
{
    while (*p == ' ' || *p == '\t')
        p++;
    if (!*p)
        return NULL;

    size_t i = 0;
    while (*p && *p != ' ' && *p != '\t' && *p != '\r' && *p != '\n') {
        if (i + 1 >= n)
            return NULL;            /* over-length: reject the whole line */
        out[i++] = *p++;
    }
    out[i] = '\0';
    return p;
}

/* True if the line has nothing left but whitespace. Used to reject commands
 * with EXTRA arguments: "CMD reboot now" is not a reboot request that happens
 * to have a stray word, it is a line we do not understand, and acting on the
 * part we recognise is exactly the failure this file exists to avoid. */
static bool at_end(const char *p)
{
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')
        p++;
    return *p == '\0';
}

cyd_cmd_kind_t cyd_cmd_parse(const char *line, cyd_cmd_t *out)
{
    if (!line || !out)
        return CYD_CMD_KIND_NONE;

    memset(out, 0, sizeof *out);
    out->kind = CYD_CMD_KIND_NONE;

    /* PING first: it has no CMD prefix. */
    if (strncmp(line, CYD_MSG_PING, strlen(CYD_MSG_PING)) == 0 &&
        at_end(line + strlen(CYD_MSG_PING))) {
        out->kind = CYD_CMD_KIND_PING;
        return out->kind;
    }

    size_t pre = strlen(CYD_CMD_PREFIX);
    if (strncmp(line, CYD_CMD_PREFIX, pre) != 0)
        return CYD_CMD_KIND_NONE;

    const char *p = line + pre;
    char verb[32];
    p = token(p, verb, sizeof verb);
    if (!p)
        return CYD_CMD_KIND_NONE;

    if (strcmp(verb, CYD_CMD_RESET_STAT) == 0) {
        if (!at_end(p)) return CYD_CMD_KIND_NONE;
        out->kind = CYD_CMD_KIND_RESET_STATS;
        return out->kind;
    }

    if (strcmp(verb, CYD_CMD_WIFI_SCAN) == 0) {
        if (!at_end(p)) return CYD_CMD_KIND_NONE;   /* takes no arguments */
        out->kind = CYD_CMD_KIND_WIFI_SCAN;
        return out->kind;
    }

    if (strcmp(verb, CYD_CMD_RESTART) == 0) {
        if (!at_end(p)) return CYD_CMD_KIND_NONE;   /* takes no arguments */
        out->kind = CYD_CMD_KIND_RESTART;
        return out->kind;
    }

    /* set_wifi <ssid> <psk>
     *
     * The PSK is the LAST field and is taken WHOLE, spaces and all, because
     * WPA passphrases routinely contain them and a token split would silently
     * truncate one -- giving a board that cannot join, with a config that
     * looks right. An SSID containing spaces is not supported and is rejected
     * rather than half-read. */
    if (strcmp(verb, CYD_CMD_SET_WIFI) == 0) {
        p = token(p, out->ssid, sizeof out->ssid);
        if (!p || !out->ssid[0]) goto bad;
        while (*p == ' ' || *p == '\t') p++;
        if (!*p) goto bad;                  /* an open network is not this */
        snprintf(out->psk, sizeof out->psk, "%s", p);

        /* REJECT " AND \ IN BOTH FIELDS.
         *
         * The daemon writes these into wpa_supplicant.conf as ssid="%s" and
         * psk="%s". A passphrase ending in a backslash escapes the closing
         * quote; a bare quote closes the string early. Either way the config
         * does not parse, wpa_supplicant exits, and a board reached over WiFi
         * is gone until someone walks to it. This is not shell injection --
         * every system() argument here is a literal -- it is config-syntax
         * injection, and the fix belongs at the parser, not the writer.
         *
         * Refusing beats escaping: a passphrase that cannot be represented is
         * better rejected while the user is standing at the panel. */
        for (const char *q = out->ssid; *q; q++)
            if (*q == '"' || *q == '\\') goto bad;
        for (const char *q = out->psk; *q; q++)
            if (*q == '"' || *q == '\\') goto bad;

        /* Trailing whitespace would be configured literally and is almost
         * never intended. */
        size_t pn = strlen(out->psk);
        while (pn && (out->psk[pn - 1] == ' ' || out->psk[pn - 1] == '\t'))
            out->psk[--pn] = '\0';
        /* WPA2 is 8..63 characters. Rejecting here means the daemon never
         * writes a config wpa_supplicant would refuse, which would drop a
         * headless board off the network with no way back in. */
        if (pn < 8 || pn > 63) goto bad;
        out->kind = CYD_CMD_KIND_SET_WIFI;
        return out->kind;
    }

    if (strcmp(verb, CYD_CMD_REBOOT) == 0) {
        if (!at_end(p)) return CYD_CMD_KIND_NONE;
        out->kind = CYD_CMD_KIND_REBOOT;
        return out->kind;
    }

    if (strcmp(verb, CYD_CMD_FAN_BOOST) == 0) {
        char arg[8];
        p = token(p, arg, sizeof arg);
        if (!p || !at_end(p)) return CYD_CMD_KIND_NONE;
        /* Exactly "0" or "1". Not atoi(), which would read "on" as 0 and
         * quietly turn a boost request into a cancel. */
        if (strcmp(arg, "0") == 0)      out->fan_on = 0;
        else if (strcmp(arg, "1") == 0) out->fan_on = 1;
        else return CYD_CMD_KIND_NONE;
        out->kind = CYD_CMD_KIND_FAN_BOOST;
        return out->kind;
    }

    if (strcmp(verb, CYD_CMD_SET_POOL) == 0) {
        char portbuf[16];
        p = token(p, out->host, sizeof out->host);       if (!p) goto bad;
        p = token(p, portbuf,   sizeof portbuf);         if (!p) goto bad;
        p = token(p, out->worker, sizeof out->worker);   if (!p) goto bad;
        p = token(p, out->pass, sizeof out->pass);       if (!p) goto bad;
        if (!at_end(p)) goto bad;

        /* strtol with an end check, not atoi: atoi("80x") is 80, and a pool
         * port that silently drops characters is a miner that connects
         * nowhere. */
        char *end = NULL;
        long v = strtol(portbuf, &end, 10);
        if (!end || *end != '\0' || v <= 0 || v > 65535)
            goto bad;
        out->port = (int)v;

        /* pass too. token() treats CR/LF as a terminator and returns an
         * empty string rather than NULL, so
         *   CMD set_pool h 80 w <CR>
         * parsed cleanly and wrote POOL_PASS= into /boot/am01-miner.conf
         * -- a file that survives a reflash. host and worker were
         * guarded here from the start; pass was simply missed. */
        if (out->host[0] == '\0' || out->worker[0] == '\0' ||
            out->pass[0] == '\0')
            goto bad;

        out->kind = CYD_CMD_KIND_SET_POOL;
        return out->kind;
    }

bad:
    memset(out, 0, sizeof *out);
    out->kind = CYD_CMD_KIND_NONE;
    return CYD_CMD_KIND_NONE;
}
