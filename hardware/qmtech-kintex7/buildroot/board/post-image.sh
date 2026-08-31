#!/bin/sh
# Assemble output/images/sdcard.img from the kernel, DTB, Pi firmware and the
# ext4 root. Buildroot runs this after the filesystem images are built.
set -e

BOARD_DIR="$(dirname "$0")"

# Compile the FPGA pin-reservation overlay into the firmware's overlays/
# directory, which genimage copies onto the boot partition. It must be a
# compiled .dtbo -- the firmware cannot load .dts source, and anything written
# to /boot in the rootfs is hidden once boot.mount covers it.
"${HOST_DIR}/bin/dtc" -@ -I dts -O dtb -o \
	"${BINARIES_DIR}/rpi-firmware/overlays/am01-fpga-gpio.dtbo" \
	"${BOARD_DIR}/../../linux/am01-fpga-gpio.dts"

# cmdline.txt must sit next to the other boot files for genimage to pick it up.
# mmcblk0p2 is the second partition of the eMMC on a CM4.
#
# console=tty1 ONLY -- deliberately no ttyAMA0. That UART is disabled in
# config.txt because GPIO14/15 are FPGA data bus bits, and Linux makes the LAST
# console= the userspace /dev/console: naming a UART that does not exist would
# send init's output nowhere. tty1 is HDMI, which is the only early-boot
# diagnostic path on this board -- the USB gadget console cannot help until
# dwc2 and g_serial have loaded.
echo "root=/dev/mmcblk0p2 rootwait console=tty1" > "${BINARIES_DIR}/cmdline.txt"

# A WiFi credential template on the FAT boot partition. That partition mounts
# as a normal drive in Windows, so credentials can be set without a Linux box
# and without rebuilding -- and, unlike the copy in the rootfs, they survive a
# reflash. am01-wifi-provision.service installs it on boot once it is renamed
# to wpa_supplicant.conf and the placeholder password is replaced.
cat > "${BINARIES_DIR}/wpa_supplicant.conf.example" <<'WIFIEOF'
# AM01 miner WiFi credentials.
#
# TO USE: rename this file to  wpa_supplicant.conf  (drop the .example),
# replace the password below, then boot the board.
#
# Keep the QUOTES around psk. Quoted means the plaintext passphrase, which
# wpa_supplicant hashes itself. Unquoted means a 64-hex-digit precomputed
# hash -- and since that hash is salted with the SSID, one generated against
# a mistyped SSID stays silently invalid even after the SSID is corrected.
# Quoting avoids that trap completely.
ctrl_interface=/var/run/wpa_supplicant
update_config=1
country=GB

network={
    ssid="vodafoneAAB7F3"
    psk="PUT-YOUR-WIFI-PASSWORD-HERE"
    key_mgmt=WPA-PSK
    scan_ssid=1
}
WIFIEOF

# Pool configuration template, same idea as the WiFi one above: without it a
# reflash silently reverts the board to the placeholder pool, which does not
# resolve, and the miner comes up retrying a connection forever.
# am01-miner-provision.service installs it once it is renamed and edited.
cat > "${BINARIES_DIR}/am01-miner.conf.example" <<'MINEREOF'
# AM01 pool configuration.
#
# TO USE: rename this file to  am01-miner.conf  (drop the .example), put your
# own pool and wallet below, then boot the board.
#
# DAEMON_OPTS is passed to odo-miner verbatim, positionally:
#
#     DAEMON_OPTS="<host> <port> <worker> <password>"
#
# The worker is normally WALLET.WORKERNAME. Most pools ignore the password;
# "x" is the conventional placeholder.
DAEMON_OPTS="POOL-HOST 3333 YOUR_WALLET.am01 x"

# Set to 1 to drive the ILI9341 panel on JP5. Leave unset if no panel is
# fitted -- the miner runs either way and reports the panel as unavailable.
#AM01_PANEL=1

LOG_LEVEL=INFO
MINEREOF

# SSH public key template. Without this, headless access has to be rebuilt
# over the serial console after every reflash -- and this image's password
# auth does not work (see am01-ssh-provision.service), so a key is the only
# practical route in.
cat > "${BINARIES_DIR}/authorized_keys.example" <<'SSHEOF'
# AM01 SSH access.
#
# TO USE: rename this file to  authorized_keys  (drop the .example) and put
# your PUBLIC key below, one per line. Generate a pair on your machine with:
#
#     ssh-keygen -t ed25519 -f am01_key
#
# and paste the contents of am01_key.pub (the one ending .pub -- never the
# private half) here. Then:
#
#     ssh -i am01_key root@<board-ip>
#
# Keys are APPENDED to any already on the board, so adding a second machine
# does not lock out the first.
SSHEOF

exec "${HOST_DIR}/bin/genimage" \
	--rootpath "${TARGET_DIR}" \
	--tmppath "${BUILD_DIR}/genimage.tmp" \
	--inputpath "${BINARIES_DIR}" \
	--outputpath "${BINARIES_DIR}" \
	--config "${BOARD_DIR}/genimage.cfg"
