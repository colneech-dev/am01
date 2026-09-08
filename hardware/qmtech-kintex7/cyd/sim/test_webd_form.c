/*
 * test_webd_form.c -- unit test for odo-webd's form parsing, URL decoding,
 * constant-time auth comparison, and string validation security filters.
 *
 * Exercises:
 *   - url_decode() memory safety (incl. truncated '%' handling)
 *   - form_get() key extraction and buffer bounds
 *   - value_safe() and wpa_value_safe() input validation rules
 *   - ct_eq() constant-time password comparison
 *   - cookie_token() session token header parser
 */

#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <stdbool.h>

static int errors = 0, checks = 0;

static void ok(int cond, const char *what)
{
    checks++;
    if (cond) { printf("  PASS  %s\n", what); }
    else      { printf("  FAIL  %s\n", what); errors++; }
}

/* -------------------------------------------------------------------------
 * Logic under test (mirrors odo_webd_am01.c)
 * ------------------------------------------------------------------------- */

static void url_decode(char *s)
{
    char *o = s;
    while (*s) {
        if (*s == '+') { *o++ = ' '; s++; }
        else if (*s == '%' && s[1] && isxdigit((unsigned char)s[1]) &&
                 s[2] && isxdigit((unsigned char)s[2])) {
            char hex[3] = { s[1], s[2], 0 };
            *o++ = (char)strtol(hex, NULL, 16);
            s += 3;
        } else *o++ = *s++;
    }
    *o = 0;
}

static void form_get(const char *body, const char *key, char *out, size_t out_sz)
{
    out[0] = 0;
    size_t klen = strlen(key);
    const char *p = body;
    while (p && *p) {
        if (strncmp(p, key, klen) == 0 && p[klen] == '=') {
            p += klen + 1;
            size_t i = 0;
            while (*p && *p != '&' && i + 1 < out_sz)
                out[i++] = *p++;
            out[i] = 0;
            url_decode(out);
            return;
        }
        p = strchr(p, '&');
        if (p) p++;
    }
}

static int value_safe(const char *s)
{
    for (; *s; s++)
        if (!isalnum((unsigned char)*s) && !strchr(".-_:@/", *s))
            return 0;
    return 1;
}

static int wpa_value_safe(const char *s, size_t min_len, size_t max_len)
{
    size_t len = strlen(s);
    if (len < min_len || len > max_len)
        return 0;
    for (; *s; s++)
        if ((unsigned char)*s < 0x20 || (unsigned char)*s > 0x7E ||
            *s == '"' || *s == '\\')
            return 0;
    return 1;
}

static int ct_eq(const char *a, const char *b)
{
    size_t la = strlen(a), lb = strlen(b), i;
    unsigned char d = (unsigned char)(la ^ lb);
    for (i = 0; i < lb; i++) {
        unsigned char ca = (i < la) ? (unsigned char)a[i] : 0;
        d |= (unsigned char)(ca ^ (unsigned char)b[i]);
    }
    return d == 0 && la == lb;
}

static int cookie_token(const char *req, char *tok33)
{
    tok33[0] = 0;
    const char *p = req;
    while (p && *p) {
        const char *nl = strchr(p, '\n');
        size_t linelen = nl ? (size_t)(nl - p) : strlen(p);
        if (linelen == 0 || (linelen == 1 && p[0] == '\r'))
            break;
        if (strncasecmp(p, "Cookie:", 7) == 0) {
            const char *end = p + linelen;
            for (const char *c = p + 7; c < end; c++) {
                if ((size_t)(end - c) >= 11 && strncmp(c, "odosession=", 11) == 0) {
                    c += 11;
                    int i = 0;
                    while (c < end && i < 32 &&
                           *c != ';' && *c != ' ' && *c != '\t' && *c != '\r')
                        tok33[i++] = *c++;
                    tok33[i] = 0;
                    return tok33[0] != 0;
                }
            }
        }
        if (!nl) break;
        p = nl + 1;
    }
    return 0;
}

/* -------------------------------------------------------------------------
 * Test cases
 * ------------------------------------------------------------------------- */

int main(void)
{
    printf("=== test_webd_form ===\n");

    /* 1. url_decode tests */
    printf("\n-- url_decode --\n");
    {
        char b1[64] = "hello+world";
        url_decode(b1);
        ok(strcmp(b1, "hello world") == 0, "+ decoded to space");

        char b2[64] = "test%20value%21";
        url_decode(b2);
        ok(strcmp(b2, "test value!") == 0, "standard %20 and %21 decoded");

        /* Truncated % edge cases (BUG-01 verification) */
        char b3[64] = "bad%end%";
        url_decode(b3);
        ok(strcmp(b3, "bad%end%") == 0, "trailing standalone % handled safely without OOB");

        char b4[64] = "bad%4";
        url_decode(b4);
        ok(strcmp(b4, "bad%4") == 0, "trailing single-hex %4 handled safely");

        char b5[64] = "bad%zz";
        url_decode(b5);
        ok(strcmp(b5, "bad%zz") == 0, "non-hex percent sequence preserved safely");
    }

    /* 2. form_get tests */
    printf("\n-- form_get --\n");
    {
        const char *body = "host=stratum.pool.org&port=3333&worker=wallet.rig01&pass=x";
        char val[64];

        form_get(body, "host", val, sizeof val);
        ok(strcmp(val, "stratum.pool.org") == 0, "first param parsed");

        form_get(body, "port", val, sizeof val);
        ok(strcmp(val, "3333") == 0, "middle param parsed");

        form_get(body, "pass", val, sizeof val);
        ok(strcmp(val, "x") == 0, "last param parsed");

        form_get(body, "missing", val, sizeof val);
        ok(val[0] == '\0', "missing param returns empty string");

        char small[6];
        form_get(body, "host", small, sizeof small);
        ok(strlen(small) == 5 && strcmp(small, "strat") == 0, "buffer capacity strictly respected");
    }

    /* 3. value_safe input sanitation */
    printf("\n-- value_safe --\n");
    {
        ok(value_safe("stratum.pool.com") == 1, "valid host name accepted");
        ok(value_safe("10.0.0.2:3333") == 1, "valid ip:port accepted");
        ok(value_safe("wallet_user-01@pool") == 1, "valid characters accepted");

        ok(value_safe("host;rm -rf /") == 0, "semicolon rejected");
        ok(value_safe("host`reboot`") == 0, "backticks rejected");
        ok(value_safe("host$(reboot)") == 0, "subshell rejected");
        ok(value_safe("host\"name") == 0, "double quote rejected");
        ok(value_safe("host'name") == 0, "single quote rejected");
        ok(value_safe("host\nline") == 0, "newline rejected");
    }

    /* 4. wpa_value_safe WiFi credential checks */
    printf("\n-- wpa_value_safe --\n");
    {
        ok(wpa_value_safe("HomeNetwork_5G", 1, 32) == 1, "valid SSID accepted");
        ok(wpa_value_safe("MySecretPassword123", 8, 63) == 1, "valid 8-63 PSK accepted");

        ok(wpa_value_safe("short", 8, 63) == 0, "short password (< 8 chars) rejected");
        ok(wpa_value_safe("", 1, 32) == 0, "empty SSID rejected");

        ok(wpa_value_safe("pass\"withquote", 8, 63) == 0, "quotes in PSK rejected");
        ok(wpa_value_safe("pass\\withslash", 8, 63) == 0, "backslashes in PSK rejected");
        ok(wpa_value_safe("SSID\"Injection", 1, 32) == 0, "quotes in SSID rejected");
    }

    /* 5. ct_eq constant-time comparison */
    printf("\n-- ct_eq --\n");
    {
        ok(ct_eq("correct_password", "correct_password") == 1, "exact match passes");
        ok(ct_eq("correct_password", "wrong_password") == 0, "mismatch fails");
        ok(ct_eq("correct_password", "correct_pass") == 0, "shorter string fails");
        ok(ct_eq("correct_pass", "correct_password") == 0, "longer string fails");
        ok(ct_eq("", "password") == 0, "empty guess fails");
        ok(ct_eq("", "") == 1, "empty match passes");
    }

    /* 6. cookie_token extraction */
    printf("\n-- cookie_token --\n");
    {
        char tok[33];
        const char *req1 = "GET / HTTP/1.1\r\nHost: miner\r\nCookie: odosession=0123456789abcdef0123456789abcdef\r\n\r\n";
        ok(cookie_token(req1, tok) == 1, "valid single cookie found");
        ok(strcmp(tok, "0123456789abcdef0123456789abcdef") == 0, "token matches exactly");

        const char *req2 = "GET / HTTP/1.1\r\nCookie: other=123; odosession=fedcba9876543210fedcba9876543210; extra=1\r\n\r\n";
        ok(cookie_token(req2, tok) == 1, "middle cookie found in list");
        ok(strcmp(tok, "fedcba9876543210fedcba9876543210") == 0, "token matches exactly");

        const char *req3 = "GET / HTTP/1.1\r\nCookie: other=123\r\n\r\n";
        ok(cookie_token(req3, tok) == 0, "missing odosession returns 0");

        const char *req4 = "GET / HTTP/1.1\r\nHost: miner\r\n\r\n";
        ok(cookie_token(req4, tok) == 0, "missing Cookie header returns 0");
    }

    printf("\n=== %d/%d CHECKS PASSED ===\n", checks - errors, checks);
    return errors ? 1 : 0;
}
