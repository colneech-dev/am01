/*
 * cyd_proto.h -- wire protocol between the CM4 and the CYD front panel.
 *
 * SCAFFOLDING. Nothing builds against this yet, and nothing here touches the
 * existing ILI9341 path (cm4-firmware/am01_panel.c and the display block in
 * hdl/odocrypt_gpio_wrapper.v), which is still the live solution.
 *
 * LINE-ORIENTED TEXT, deliberately, not a packed binary struct. The link
 * carries one status update a second and the occasional touch, so there is no
 * throughput argument for binary -- and this project has repeatedly been
 * slowed by things that could not be observed. Text means the link can be
 * watched with `cat`, replayed by hand, and diagnosed without a decoder ring.
 * That is worth more here than saving a hundred bytes a second.
 *
 * Transport: a UART hosted in the FPGA, reached by the CM4 over the register
 * bus it already uses, and appearing to userspace as a PTY. See
 * docs/PLAN-cyd-display.md for why that is the only possible topology.
 */

#ifndef CYD_PROTO_H
#define CYD_PROTO_H

/* Default link speed. 115200 needs 11.5 kB/s; the register bus was measured at
 * roughly 50k writes/s on the LCD path, so there is ~5x headroom. Raising this
 * buys nothing -- the payload is one status line a second -- and spends the
 * signal-integrity margin that is the entire reason for moving off SPI. */
#define CYD_BAUD_DEFAULT 115200

/* Longest line either direction. A status line is well under this; the cap
 * exists so a desynchronised link cannot make either side allocate without
 * bound while hunting for a newline that is never coming. */
#define CYD_LINE_MAX 512

/*
 * CM4 -> CYD, once a second:
 *
 *     STATUS {"pool":"...","hashrate":68356137.0,...}\n
 *
 * The payload is /run/odod/status.json verbatim -- the same object odo-webd
 * and odo-ui already consume. Passing it through unaltered means the panel
 * cannot drift from the dashboard, and a new field needs no protocol change.
 *
 *     HELLO <proto-version> <miner-version>\n     on connect
 *     PONG\n                                      answer to PING
 */
#define CYD_MSG_STATUS "STATUS "
#define CYD_MSG_HELLO  "HELLO "
#define CYD_MSG_PONG   "PONG"

/*
 * CYD -> CM4, on a touch:
 *
 *     CMD fan_boost <0|1>
 *     CMD reset_stats
 *     CMD reboot
 *     CMD set_pool <host> <port> <worker> <pass>
 *     PING
 *
 * These land on the control surface that ALREADY EXISTS rather than inventing
 * a second one: fan_boost and reset_stats are the /run/odod/ flag files
 * odo-webd already uses, and set_pool writes /boot/am01-miner.conf, which
 * am01-miner-provision.service installs and which survives a reflash. A pool
 * changed from the panel therefore persists, and persists in the one place
 * that is already the source of truth for it.
 */
#define CYD_CMD_PREFIX     "CMD "
#define CYD_CMD_FAN_BOOST  "fan_boost"
#define CYD_CMD_RESET_STAT "reset_stats"
#define CYD_CMD_REBOOT     "reboot"
#define CYD_CMD_SET_POOL   "set_pool"
#define CYD_MSG_PING       "PING"

/* Bumped only for an INCOMPATIBLE change. Adding a status field is not one:
 * the payload is opaque JSON and an older panel ignores what it does not
 * know. HELLO carries this so a mismatch is visible on the panel rather than
 * appearing as a display that is subtly and silently wrong. */
#define CYD_PROTO_VERSION 1

/*
 * Paths the daemon acts on. Kept here so the protocol and its side effects are
 * described in one place -- these are not the daemon's private business, they
 * are what a command MEANS.
 */
#define CYD_STATUS_PATH     "/run/odod/status.json"
#define CYD_FAN_BOOST_PATH  "/run/odod/fan_boost"
#define CYD_RESET_STAT_PATH "/run/odod/reset_stats"
#define CYD_POOL_CONF_PATH  "/boot/am01-miner.conf"

/*
 * FPGA registers this rides on. NOT YET IMPLEMENTED -- hdl/uart_bridge.v does
 * not exist. Listed so the host and RTL halves are designed against one
 * definition instead of two that drift.
 *
 * Addresses continue the map in odocrypt_gpio_wrapper.v, which is 5 bits wide
 * and currently used up to 0x18 (FIFO_STAT).
 */
#define CYD_REG_UART_DATA 0x19  /* w: push TX byte   r: pop RX byte        */
#define CYD_REG_UART_STAT 0x1A  /* r: tx_free, rx_avail, FIFO depths       */
#define CYD_REG_ESP_CTRL  0x1B  /* w: [0] EN, [1] IO0 -- ESP32 boot select */

/* Bit positions within CYD_REG_ESP_CTRL. Two plain output bits on purpose:
 * the ROM bootloader is entered by a specific EN/IO0 sequence with timing that
 * varies between modules, and that belongs in software where it can be
 * adjusted, not frozen into a state machine that needs a 1h35m rebuild to
 * change. */
#define CYD_ESP_CTRL_EN  (1u << 0)
#define CYD_ESP_CTRL_IO0 (1u << 1)

#endif /* CYD_PROTO_H */
