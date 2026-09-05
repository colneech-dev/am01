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
#define CYD_CMD_WIFI_SCAN  "wifi_scan"

/*
 * CM4 -> CYD, firmware update:
 *
 *     OTABEGIN <bytes> <md5-hex>\n
 *     OTA <base64 of up to CYD_OTA_CHUNK bytes>\n     ... many
 *     OTAEND\n
 *
 * CYD -> CM4:
 *
 *     OTAOK <bytes-so-far>\n      after each chunk, and once after OTAEND
 *     OTAERR <text>\n             aborted; the running firmware is untouched
 *
 * WHY THE APPLICATION AND NOT esptool. The ESP32 ROM bootloader listens on
 * UART0 (GPIO1/GPIO3) and nowhere else. This link is Serial2 on CN1
 * (GPIO27/22), chosen to escape the CH340C contention on UART0 documented in
 * docs/JP5-WIRING.md. So no amount of EN/IO0 control or
 * RTC_CNTL_FORCE_DOWNLOAD_BOOT can make the ROM listen here -- forcing
 * download mode only parks the chip on the pins we deliberately abandoned.
 * am01-uartd's PTY flash mode was designed before that move and cannot work
 * as written.
 *
 * The application can do it, because the panel writes its own spare OTA slot:
 * the image is 485KB against two 1.25MB slots in the default 4MB scheme.
 *
 * BASE64 rather than raw bytes, because this protocol is line-oriented and
 * stays that way -- a length-prefixed binary frame would need every reader on
 * both sides to learn a second framing. The 33% cost is affordable: 485KB
 * becomes ~650KB, which at 115200 baud is under a minute, once per update.
 *
 * ACK PER CHUNK, not a blind stream. The panel writes each chunk to flash
 * before acknowledging, so the host cannot outrun an erase; this is flow
 * control that costs one short line per chunk.
 *
 * WHAT THIS CANNOT DO: recover a panel whose firmware does not BOOT. The
 * receiver lives in the application, so it needs the application running.
 * Rollback on a non-booting image needs bootloader support that the Arduino
 * framework does not enable, so the protection here is to verify the MD5
 * BEFORE the boot partition is switched -- a corrupt transfer can never be
 * booted. A genuinely broken but valid image still needs USB.
 */
#define CYD_MSG_OTABEGIN "OTABEGIN "
#define CYD_MSG_OTADATA  "OTA "
#define CYD_MSG_OTAEND   "OTAEND"
#define CYD_MSG_OTAOK    "OTAOK "
#define CYD_MSG_OTAERR   "OTAERR "

/*
 * CM4 -> CYD, in reply to "CMD wifi_scan":
 *
 *     SCANBEGIN\n
 *     SCAN <dbm> <ssid>\n     ... strongest first, at most CYD_SCAN_MAX
 *     SCANEND\n
 *
 * THE MINER SCANS. The panel has a radio of its own and could do this
 * unaided, but it is the CM4 that associates -- offering a list the panel can
 * hear and the miner cannot join would be worse than offering no list. The
 * two are inches apart and will nearly always agree; nearly is the problem.
 *
 * SSIDs may contain spaces, so the SSID is the REST OF THE LINE after the
 * dbm field and is not tokenised further. They may also contain almost
 * anything else, which is why the panel treats one only as a string to
 * display and to copy into its SSID field -- never as anything to execute.
 */
#define CYD_MSG_SCANBEGIN "SCANBEGIN"
#define CYD_MSG_SCAN      "SCAN "
#define CYD_MSG_SCANEND   "SCANEND"

/* Twelve is what fits on the picker without scrolling, and more than anyone
 * needs to find their own network. */
#define CYD_SCAN_MAX 12

/* Where the helper leaves the results for the panel thread to forward. */
#define CYD_WIFI_SCAN_PATH "/run/odod/wifi_scan.txt"

/* Raw bytes per chunk. 512 -> 684 base64 characters, comfortably inside
 * CYD_LINE_MAX with the prefix, and a whole number of flash words. */
#define CYD_OTA_CHUNK 512

/* An erase can stall a write for a while; the host must not give up early. */
#define CYD_OTA_ACK_TIMEOUT_MS 10000

/* Refuse anything that cannot be a valid image for this board, before a
 * single byte is written. Upper bound is the 1.25MB OTA slot. */
#define CYD_OTA_MIN_BYTES 65536
#define CYD_OTA_MAX_BYTES (1280 * 1024)

/* The host writes the image here and touches the .req file; the panel thread
 * inside odo-miner streams it. A file rather than a socket because the miner
 * already owns the bus exclusively (libgpiod line requests are exclusive), so
 * a separate flashing process cannot open the link while mining. */
#define CYD_OTA_IMAGE_PATH "/run/odod/panel-ota.bin"
#define CYD_OTA_REQ_PATH   "/run/odod/panel-ota.req"

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
/* Regulatory domain written into wpa_supplicant.conf. NOT optional: without
 * country= the regdomain stays at world (00), the firmware refuses the
 * channel, and wlan0 sits in SCANNING with the radio working perfectly. Match
 * this to the shipped overlay config if the board moves country. */
#define CYD_WIFI_COUNTRY    "GB"
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
/* r: RX FIFO occupancy, exact, 16 bits.
 *
 * UART_STAT carries a 5-bit rx_cnt that saturates at 31 -- fine for
 * "is there anything", useless for "how much" once the FIFO grew to
 * 256 bytes. This is the honest number, and having it here means the
 * FIFO can be resized again without touching a bitfield or a host. */
#define CYD_REG_UART_RXCNT 0x1C

/* Bit positions within CYD_REG_ESP_CTRL. Two plain output bits on purpose:
 * the ROM bootloader is entered by a specific EN/IO0 sequence with timing that
 * varies between modules, and that belongs in software where it can be
 * adjusted, not frozen into a state machine that needs a 1h35m rebuild to
 * change. */
#define CYD_ESP_CTRL_EN  (1u << 0)
#define CYD_ESP_CTRL_IO0 (1u << 1)

#endif /* CYD_PROTO_H */
