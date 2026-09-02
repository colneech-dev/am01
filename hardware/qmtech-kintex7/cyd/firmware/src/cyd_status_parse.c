/*
 * cyd_status_parse.c -- turn one STATUS line into a cyd_status_t.
 *
 * PURE C, NO TRANSPORT, NO ESP32. Which means sim/test_cyd_status_parse.c
 * runs it on a PC against the miner's REAL status.json, captured from the
 * board. That matters more here than anywhere else in the panel: this is the
 * one place where a silent misread turns into a display that is confidently
 * wrong, and a panel reporting the wrong hashrate looks exactly like a panel
 * reporting the right one.
 *
 * A HAND-ROLLED SCANNER, not a JSON library. The payload is a flat object of
 * known keys emitted by one program (miner_pipe_am01.c's status_write), so
 * the general case is not needed -- and ArduinoJson would be a third
 * dependency plus a heap allocator on a panel that has neither. What this
 * does NOT do is validate: it looks for "key": and reads what follows. A
 * malformed line yields whatever it can find and leaves the rest alone,
 * which is the right failure for a status display.
 *
 * The status object is passed through the link verbatim, so adding a field to
 * the miner needs no protocol change and no change here until something wants
 * to draw it.
 */

#include "cyd_status_parse.h"

#include <stdlib.h>
#include <string.h>

/* Find "key" and return the first character of its value, or NULL.
 *
 * Matches the QUOTED key followed by a colon, not a bare substring. Without
 * the quotes, "epoch" would match inside "epoch_next" and "bitstream_epoch" --
 * and since those hold plausible-looking numbers, the result would be a panel
 * that is wrong in a way nothing looks odd about. */
static const char *find_val(const char *s, const char *key)
{
    char pat[48];
    size_t n = strlen(key);
    if (n + 3 >= sizeof pat)
        return NULL;
    pat[0] = '"';
    memcpy(pat + 1, key, n);
    pat[n + 1] = '"';
    pat[n + 2] = '\0';

    const char *p = strstr(s, pat);
    if (!p)
        return NULL;
    p += n + 2;
    while (*p == ' ' || *p == '\t')
        p++;
    if (*p != ':')
        return NULL;            /* the key appeared as a VALUE, not a key */
    p++;
    while (*p == ' ' || *p == '\t')
        p++;
    return *p ? p : NULL;
}

static int get_double(const char *s, const char *key, double *out)
{
    const char *p = find_val(s, key);
    if (!p)
        return 0;
    char *end = NULL;
    double v = strtod(p, &end);
    if (end == p)
        return 0;
    *out = v;
    return 1;
}

static int get_int(const char *s, const char *key, int *out)
{
    double v;
    if (!get_double(s, key, &v))
        return 0;
    *out = (int)v;
    return 1;
}

static int get_u32(const char *s, const char *key, uint32_t *out)
{
    double v;
    if (!get_double(s, key, &v))
        return 0;
    /* Clamped rather than cast blind. A negative here would wrap to a huge
     * value and, in epoch_next, produce a countdown of decades. */
    *out = (v < 0.0) ? 0u : (uint32_t)v;
    return 1;
}

static int get_u64(const char *s, const char *key, uint64_t *out)
{
    double v;
    if (!get_double(s, key, &v))
        return 0;
    *out = (v < 0.0) ? 0u : (uint64_t)v;
    return 1;
}

static int get_bool(const char *s, const char *key, bool *out)
{
    const char *p = find_val(s, key);
    if (!p)
        return 0;
    if (strncmp(p, "true", 4) == 0)  { *out = true;  return 1; }
    if (strncmp(p, "false", 5) == 0) { *out = false; return 1; }
    return 0;
}

/* Copy a JSON string value. ALWAYS terminates, and truncates rather than
 * overrunning -- these land in fixed char arrays inside cyd_status_t and the
 * pool string in particular is host:port from a config file, so its length is
 * not ours to assume. */
static int get_str(const char *s, const char *key, char *out, size_t n)
{
    const char *p = find_val(s, key);
    if (!p || *p != '"' || n == 0)
        return 0;
    p++;
    size_t i = 0;
    while (*p && *p != '"' && i + 1 < n) {
        if (*p == '\\' && p[1])     /* keep escapes readable, do not decode */
            p++;
        out[i++] = *p++;
    }
    out[i] = '\0';
    return 1;
}

bool cyd_status_parse(const char *json, cyd_status_t *st)
{
    if (!json || !st)
        return false;

    /* hashrate is the field that decides whether this looked like a status
     * object at all. Chosen because it is always present and always numeric;
     * a line missing it is not one worth half-applying. */
    double hr;
    if (!get_double(json, "hashrate", &hr))
        return false;

    st->hashrate = hr;
    st->valid    = true;
    st->age_ms   = 0;

    get_bool(json, "connected", &st->connected);
    get_str (json, "pool",    st->pool,    sizeof st->pool);
    get_str (json, "job_id",  st->job_id,  sizeof st->job_id);
    get_str (json, "backend", st->backend, sizeof st->backend);
    get_str (json, "core",    st->core,    sizeof st->core);

    get_u64(json, "shares_found",    &st->shares_found);
    get_u64(json, "shares_accepted", &st->shares_accepted);
    get_u64(json, "shares_rejected", &st->shares_rejected);
    get_u64(json, "blocks_found",    &st->blocks_found);

    get_double(json, "best_diff_session", &st->best_diff_session);
    get_double(json, "best_diff_alltime", &st->best_diff_alltime);

    get_u32(json, "epoch",           &st->epoch);
    get_u32(json, "bitstream_epoch", &st->bitstream_epoch);
    get_u32(json, "epoch_next",      &st->epoch_next);
    get_u32(json, "uptime",          &st->uptime);
    get_u32(json, "last_share",      &st->last_share);

    /* NOT clamped to zero: -1 is the miner's "could not read" sentinel and
     * cyd_fmt_temp/cyd_fmt_fan turn it into "--". Forcing it to 0 here would
     * render as "0 C" and "0 rpm" -- a cold board and a stopped fan, both
     * untrue and both alarming. */
    get_int(json, "temp_c",       &st->temp_c);
    get_int(json, "fan_rpm",      &st->fan_rpm);
    get_int(json, "fan_duty_pct", &st->fan_duty_pct);

    return true;
}
