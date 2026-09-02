/*
 * cyd_link.h -- the miner link, as seen from the ESP32.
 *
 * SCAFFOLDING. Not compiled into anything yet.
 *
 * Transport-agnostic, so the UI never reaches into a Serial object directly.
 * That still matters even with one transport: it is what lets the screen
 * logic be exercised off-hardware.
 *
 * THERE IS ONLY ONE TRANSPORT, AND IT IS THE UART. A WiFi implementation was
 * declared here as scaffolding, to let the UI progress while uart_bridge.v
 * was still being written. It was removed on 2026-09-01, unimplemented:
 *
 *   - the requirement was always "over wires, not USB, not WiFi", which
 *     docs/PLAN-cyd-display.md states in its own opening line
 *   - uart_bridge.v now exists, passes 22/22, and its registers are in the
 *     bitstream, so the reason to defer the real link is gone
 *   - it was the DEFAULT (CYD_USE_UART defaulted to 0), so a build of
 *     main.cpp would have quietly used the transport that was ruled out
 *   - a WiFi panel would need the network credentials stored a second time,
 *     in the firmware, when they already live on the Pi
 *
 * The protocol constants live in ../host/cyd_proto.h and are shared with the
 * daemon on the CM4. One definition for both halves, so they cannot drift --
 * the same reason miner_pipe_am01.c and the RTL share a register map.
 */

#ifndef CYD_LINK_H
#define CYD_LINK_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <stdbool.h>

/* INCLUDED, not merely referenced in a comment. The protocol constants are
 * shared with the CM4 daemon, and "shared" only means anything if both sides
 * actually compile against the same file -- a comment saying where they live
 * lets them drift, which is the failure this is meant to prevent.
 *
 * Found on the include path (platformio.ini adds ../host, and the host-side
 * test uses -I) rather than by a relative "../host/..." -- that form silently
 * depended on this header sitting in the firmware root, and broke the moment
 * it moved into include/. */
#include "cyd_proto.h"

/* Mirrors the fields the miner publishes in /run/odod/status.json, which is
 * the same object odo-webd and odo-ui already consume.
 *
 * NOT every field is here -- only what the screens draw. The link passes the
 * JSON through verbatim, so adding a field to the miner needs no protocol
 * change and no change here until something wants to display it.
 *
 * Sentinels matter: temp_c and fan_rpm are -1 when the miner cannot read
 * them, and the panel must show that as unknown rather than as "-1 C", which
 * would look like a fault in the board rather than a gap in the reporting.
 *
 * They WERE -1 permanently until 2026-09-01, because the daemon was built
 * against the Cyclone V's thermal.c -- a DS18B20 on an Avalon-MM PIO reached
 * through /dev/mem, none of which exists on this board. sw/thermal_am01.c now
 * reads the FPGA's XADC and tach registers instead and the fields are live.
 * The sentinel handling stays: it is still the right behaviour for a bus read
 * that fails, it just is not the permanent state any more.
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

/* The link: an FPGA-hosted UART on JP5 15-18, reached by the CM4 over the
 * register bus it already uses. See docs/PLAN-cyd-display.md for why that is
 * the only topology this hardware allows. */
cyd_link_t *cyd_link_uart_open(int baud);

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

#ifdef __cplusplus
}
#endif

#endif /* CYD_LINK_H */
