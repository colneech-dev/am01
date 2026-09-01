/*
 * cyd_link.h -- the miner link, as seen from the ESP32.
 *
 * SCAFFOLDING. Not compiled into anything yet.
 *
 * Deliberately transport-agnostic. The plan develops the UI over WiFi first,
 * so the panel can be worked on while hdl/uart_bridge.v is still being
 * written, then switches to the UART by swapping ONE implementation behind
 * this interface. If the UI ever reaches into a Serial object directly, that
 * switch stops being a swap and becomes a rewrite.
 *
 * The protocol constants live in ../host/cyd_proto.h and are shared with the
 * daemon on the CM4. One definition for both halves, so they cannot drift --
 * the same reason miner_pipe_am01.c and the RTL share a register map.
 */

#ifndef CYD_LINK_H
#define CYD_LINK_H

#include <stdint.h>
#include <stdbool.h>

/* INCLUDED, not merely referenced in a comment. The protocol constants are
 * shared with the CM4 daemon, and "shared" only means anything if both sides
 * actually compile against the same file -- a comment saying where they live
 * lets them drift, which is the failure this is meant to prevent. */
#include "../host/cyd_proto.h"

/* Mirrors the fields the miner publishes in /run/odod/status.json, which is
 * the same object odo-webd and odo-ui already consume.
 *
 * NOT every field is here -- only what the screens draw. The link passes the
 * JSON through verbatim, so adding a field to the miner needs no protocol
 * change and no change here until something wants to display it.
 *
 * Sentinels matter: temp_c and fan_rpm come through as -1 when the miner
 * cannot read them (it runs as user 'miner' and its thermal init fails on
 * /dev/mem). The panel must show those as unknown rather than as "-1 C",
 * which would look like a fault in the board rather than in the reporting.
 */
typedef struct {
    bool     valid;             /* false until a STATUS has ever arrived   */
    uint32_t age_ms;            /* since the last STATUS -- drives MINER DOWN */

    bool     connected;         /* pool reachable                          */
    char     pool[64];
    char     job_id[24];
    char     backend[16];       /* "gpio"                                  */
    char     core[16];          /* "pipelined"                             */

    double   hashrate;          /* H/s                                     */
    uint64_t shares_found;
    uint64_t shares_accepted;
    uint64_t shares_rejected;
    uint64_t blocks_found;
    double   best_diff_session;
    double   best_diff_alltime;

    uint32_t epoch;
    uint32_t bitstream_epoch;   /* != epoch means the bitstream is stale   */
    uint32_t epoch_next;

    int      temp_c;            /* -1 = unknown, see above                 */
    int      fan_rpm;           /* -1 = unknown                            */
    int      fan_duty_pct;

    uint32_t uptime;
    uint32_t last_share;
} cyd_status_t;

/* One STATUS line a second is the design point, so a link that has produced
 * nothing for several seconds has genuinely gone away rather than being
 * momentarily quiet. The panel shows MINER DOWN past this -- odo-ui has the
 * same state and it is worth keeping: a stale reading presented as live is
 * worse than an honest "no data". */
#define CYD_LINK_STALE_MS 5000

typedef struct cyd_link cyd_link_t;

/* Transport implementations. Exactly one is linked in.
 *   cyd_link_uart_*   the real thing: FPGA-hosted UART over JP5
 *   cyd_link_wifi_*   development only: polls odo-webd's /status.json
 */
cyd_link_t *cyd_link_uart_open(int baud);
cyd_link_t *cyd_link_wifi_open(const char *host, int port);

/* Pump the link. Call often; never blocks. Returns true if `out` was updated
 * by a fresh STATUS this call. */
bool cyd_link_poll(cyd_link_t *link, cyd_status_t *out);

/* Commands. Return false if the link is down -- the CALLER must surface that,
 * because a button that silently does nothing is worse than one that reports
 * it could not. */
bool cyd_link_fan_boost(cyd_link_t *link, bool on);
bool cyd_link_reset_stats(cyd_link_t *link);
bool cyd_link_reboot(cyd_link_t *link);
bool cyd_link_set_pool(cyd_link_t *link, const char *host, int port,
                       const char *worker, const char *pass);

#endif /* CYD_LINK_H */
