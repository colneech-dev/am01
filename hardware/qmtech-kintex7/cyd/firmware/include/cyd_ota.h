/*
 * cyd_ota -- receive a firmware image over the panel link and boot it.
 *
 * WHY THIS EXISTS AT ALL, given esptool is right there. The ESP32 ROM
 * bootloader listens on UART0 (GPIO1/GPIO3) and nowhere else. This link is
 * Serial2 on CN1 (GPIO27/22), moved there to escape the CH340C contention on
 * UART0 that docs/JP5-WIRING.md documents. No amount of EN/IO0 control or
 * RTC_CNTL_FORCE_DOWNLOAD_BOOT changes that: forcing download mode parks the
 * ROM on the two pins we deliberately stopped using. So the update has to be
 * done by the running application, which CAN write the other OTA slot.
 *
 * The panel is 485KB against two 1.25MB slots in the default 4MB scheme, so
 * the spare slot always has room for a full image.
 *
 * SAFETY, AND ITS LIMIT. The MD5 is checked BEFORE the boot partition is
 * switched, so a corrupted transfer can never be booted -- that is the failure
 * this protects against, and it is the likely one. It does NOT protect against
 * an image that transfers perfectly and then crashes on boot: rolling that
 * back needs bootloader support the Arduino framework does not enable, and
 * recovery is over USB. Do not treat a successful OTA as proof the firmware
 * is good; treat it as proof the BYTES are good.
 */
#ifndef CYD_OTA_H
#define CYD_OTA_H

#include <Arduino.h>
#include <stdbool.h>

/* True from OTABEGIN until the reboot or an abort. The UI uses this to stop
 * drawing the normal screen: a repaint mid-update is wasted work, and the
 * operator wants to see progress, not a stale hashrate. */
bool cyd_ota_active(void);

/* 0..100, meaningful only while active. */
int cyd_ota_percent(void);

/*
 * The last error, CONSUMED BY READING: returns "" on the second call.
 *
 * One-shot on purpose. The caller draws the failure when it sees one, and a
 * sticky error would have it repainting that screen every pass of the loop --
 * a full-screen redraw forever, over the top of the live status the panel
 * should have gone back to showing.
 */
const char *cyd_ota_take_error(void);

/*
 * Offer a received line to the updater. Returns true if it was an OTA message
 * and has been dealt with (including by rejecting it) -- in which case the
 * caller must not parse it further.
 *
 * Replies are written to `reply`, which is the same stream the line arrived
 * on. Every chunk is acknowledged only after it is in flash, which is what
 * stops the host outrunning an erase.
 */
bool cyd_ota_handle_line(const char *line, Stream &reply);

#endif /* CYD_OTA_H */
