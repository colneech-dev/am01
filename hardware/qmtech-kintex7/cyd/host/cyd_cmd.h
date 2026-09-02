/*
 * cyd_cmd.h -- parse one line from the panel into a command.
 *
 * PURE, and separate from anything that acts on the result. The panel can
 * reboot the miner and rewrite the pool configuration that survives a
 * reflash, so what a line MEANS is worth deciding somewhere that can be
 * exercised exhaustively on a PC -- see sim/test_cyd_cmd.c.
 *
 * The trust boundary here is physical: the link is four wires inside a case,
 * so this is not defending against an attacker. It is defending against a
 * corrupted line, a half-received line, and a firmware bug on the far end --
 * all of which are ordinary on a serial link, and any of which could
 * otherwise write nonsense into /boot/am01-miner.conf and stop the miner
 * booting into a working pool.
 */

#ifndef CYD_CMD_H
#define CYD_CMD_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* CYD_CMD_KIND_*, not CYD_CMD_* -- cyd_proto.h already owns the CYD_CMD_
 * prefix for the WIRE STRINGS ("reboot", "set_pool", ...). Two namespaces for
 * two different things: what goes on the wire, and what the daemon decided a
 * line meant. Collapsing them collides, which is how this was discovered. */
typedef enum {
    CYD_CMD_KIND_NONE = 0,      /* not a command, or not a valid one */
    CYD_CMD_KIND_PING,
    CYD_CMD_KIND_FAN_BOOST,
    CYD_CMD_KIND_RESET_STATS,
    CYD_CMD_KIND_REBOOT,
    CYD_CMD_KIND_SET_POOL
} cyd_cmd_kind_t;

/* Sized to match what the miner's own config accepts. Deliberately generous
 * for worker, which carries a wallet address plus a worker suffix. */
typedef struct {
    cyd_cmd_kind_t kind;
    int            fan_on;        /* CYD_CMD_KIND_FAN_BOOST */
    char           host[64];      /* CYD_CMD_KIND_SET_POOL  */
    int            port;
    char           worker[128];
    char           pass[64];
} cyd_cmd_t;

/*
 * Parse one line. Returns the kind, and fills *out.
 *
 * REJECTS RATHER THAN GUESSES. A line that is malformed, over-length, has the
 * wrong number of fields, or carries an out-of-range port yields
 * CYD_CMD_KIND_NONE, because the alternative -- acting on a partially understood
 * reboot or pool change -- is worse than ignoring it. The panel will resend.
 *
 * Does not modify `line`.
 */
cyd_cmd_kind_t cyd_cmd_parse(const char *line, cyd_cmd_t *out);

#ifdef __cplusplus
}
#endif

#endif /* CYD_CMD_H */
