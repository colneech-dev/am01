/*
 * cyd_proto.h -- wire protocol between the CM4 and the CYD front panel.
 *
 * Compiled by BOTH halves -- the ESP32 firmware (via -I../host) and the CM4
 * daemon -- which is the only thing that stops the protocol becoming two
 * subtly different protocols.
 *
 * Nothing here touches the existing ILI9341 path (cm4-firmware/am01_panel.c
 * and the display block in hdl/odocrypt_gpio_wrapper.v), which remains the
 * live solution and now keeps its own JP5 pins.
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

/* Longest line either direction. The cap exists so a desynchronised link
 * cannot make either side allocate without bound hunting for a newline that
 * is never coming.
 *
 * 1024, NOT 512. "A status line is well under this" was simply wrong: the
 * miner's status.json measures 655 bytes on the board, and "STATUS " + 655
 * needs 663. At 512 the daemon truncated it to 511 and the firmware then
 * discarded every line as an overflow -- so the panel would have sat on
 * MINER DOWN for ever, with both ends behaving exactly as designed.
 *
 * Sized against a MEASURED payload with room for the miner to gain fields,
 * which it will. */
#define CYD_LINE_MAX 1024

/* The most status.json the daemon may ship, derived so the two ends CANNOT
 * disagree.
 *
 * The firmware accepts CYD_LINE_MAX-1 characters before the newline, and the
 * daemon prepends "STATUS " and appends "\n". Both sides now compute their
 * limit from this one expression instead of each sizing a buffer and hoping.
 * They did not agree before: the daemon could emit 1030 characters into a
 * 1023-character receiver, so every line would have been dropped. */
#define CYD_STATUS_BODY_MAX \
    (CYD_LINE_MAX - (int)sizeof(CYD_MSG_STATUS) - 1)

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
#define CYD_CMD_RESTART    "restart"
#define CYD_CMD_SET_WIFI   "set_wifi"
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
/* wpa_supplicant's per-interface config. Holds a PSK, so it is written
 * 0600 and its contents are NEVER logged. */
#define CYD_WPA_CONF_PATH   "/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"

/*
 * FPGA registers this rides on. IMPLEMENTED as of VERSION 0x0202 --
 * hdl/uart_bridge.v is instantiated by odocrypt_gpio_wrapper.v on JP5 15-18.
 * A bitstream reporting less than 0x0202 has no UART, and reads of these
 * addresses return zeros from unmapped space rather than failing, so
 * am01-uartd must CHECK THE VERSION instead of inferring a dead panel.
 *
 * Addresses continue the map in odocrypt_gpio_wrapper.v, which is 5 bits wide
 * and was used up to 0x18 (FIFO_STAT) before these.
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
