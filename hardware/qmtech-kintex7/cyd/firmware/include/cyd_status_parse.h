/*
 * cyd_status_parse.h -- one STATUS line -> cyd_status_t.
 *
 * Split out from the transport so it can be tested on a PC against the
 * miner's real status.json. See cyd_status_parse.c for why that split earns
 * its keep here in particular.
 */

#ifndef CYD_STATUS_PARSE_H
#define CYD_STATUS_PARSE_H

#include "cyd_link.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Fill *st from a JSON status object (the payload of a STATUS line, or the
 * body odo-webd serves).
 *
 * Returns false and touches nothing if the line does not look like a status
 * object. Returns true having applied every field it recognised; fields it
 * does not find are LEFT ALONE, so a caller that keeps one cyd_status_t
 * across updates retains the last known value rather than having it zeroed
 * by a truncated line.
 *
 * Does NOT validate the JSON. A malformed line yields what could be read.
 * That is the right failure for a status display: showing most of the truth
 * beats showing none of it. */
bool cyd_status_parse(const char *json, cyd_status_t *st);

#ifdef __cplusplus
}
#endif

#endif /* CYD_STATUS_PARSE_H */
