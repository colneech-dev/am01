#!/bin/sh
# Runs after the rootfs overlay has been copied, which is why the WiFi
# credential file cannot be chmod'ed from the package -- packages install
# before overlays are applied.
set -e

SSHD="${TARGET_DIR}/etc/ssh/sshd_config"

# OpenSSH ships PermitRootLogin commented out, so its built-in default of
# prohibit-password applies: root cannot log in with a password, and the
# image's root password is useless over the network. This is a headless
# miner with only root defined, so allow it -- otherwise the only way in is
# the USB gadget console.
#
# Weak by design for a LAN appliance: change the password on first login
# (passwd) and preferably drop an authorized_keys in and set this back to
# prohibit-password.
if [ -f "$SSHD" ]; then
	if grep -qE '^[#[:space:]]*PermitRootLogin' "$SSHD"; then
		sed -i 's|^[#[:space:]]*PermitRootLogin.*|PermitRootLogin yes|' "$SSHD"
	else
		echo 'PermitRootLogin yes' >> "$SSHD"
	fi
fi

WPA="${TARGET_DIR}/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"

# The file is gitignored because it holds a credential, so a fresh clone will
# not have it. Missing means "no WiFi configured", not a build failure.
if [ -f "$WPA" ]; then
	chmod 0600 "$WPA"
else
	echo "post-build: no wpa_supplicant-wlan0.conf; WiFi will not associate." >&2
fi

# ---------------------------------------------------------------------------
# esptool, for flashing the CYD front panel FROM the miner.
#
# The panel's ESP32 hangs off the FPGA's UART (JP5 15/16) and its EN/IO0 lines,
# so the board can reset it into the ROM bootloader on its own -- but only if
# something here speaks the Espressif download protocol. There is no python3 in
# this image and no Buildroot package for esptool, so we ship Espressif's own
# PyInstaller build: one static-ish aarch64 binary, no interpreter needed.
#
# Cached under linux/dl so a rebuild does not re-download 75MB, and gitignored
# because a third-party binary does not belong in the tree. Verified by hash --
# this lands in the image with root privileges and is fetched over the network.
#
# A missing or unverifiable download WARNS rather than fails: an image without
# esptool still mines, and breaking a multi-hour build over a network blip
# would be worse. The warning says exactly what is missing.
ESPTOOL_VER="5.3.0"
ESPTOOL_SHA="5a03918919f0b94222b639803e97e74d679d0fc3c5092cf27292f8e5a1430794"
ESPTOOL_TGZ="esptool-v${ESPTOOL_VER}-linux-aarch64.tar.gz"
ESPTOOL_URL="https://github.com/espressif/esptool/releases/download/v${ESPTOOL_VER}/${ESPTOOL_TGZ}"
DL_DIR="${BR2_EXTERNAL_AM01_PATH}/../linux/dl"

install_esptool() {
	mkdir -p "$DL_DIR"
	if [ ! -f "$DL_DIR/$ESPTOOL_TGZ" ]; then
		echo "post-build: fetching esptool v${ESPTOOL_VER} (aarch64)..."
		curl -fsSL -o "$DL_DIR/$ESPTOOL_TGZ.part" "$ESPTOOL_URL" || return 1
		mv "$DL_DIR/$ESPTOOL_TGZ.part" "$DL_DIR/$ESPTOOL_TGZ"
	fi

	echo "${ESPTOOL_SHA}  ${DL_DIR}/${ESPTOOL_TGZ}" | sha256sum -c - >/dev/null 2>&1 || {
		echo "post-build: esptool checksum MISMATCH -- refusing to install it." >&2
		rm -f "$DL_DIR/$ESPTOOL_TGZ"
		return 1
	}

	# Only the flasher. espefuse and espsecure are another 43MB and can do
	# irreversible things to a chip; nothing here needs them.
	tar xzf "$DL_DIR/$ESPTOOL_TGZ" -C "$DL_DIR" \
		"esptool-linux-aarch64/esptool" || return 1
	install -D -m 0755 "$DL_DIR/esptool-linux-aarch64/esptool" \
		"${TARGET_DIR}/usr/bin/esptool" || return 1
	echo "post-build: installed esptool v${ESPTOOL_VER} to /usr/bin/esptool"
}

if ! install_esptool; then
	echo "post-build: esptool NOT installed; the CYD cannot be flashed from the board." >&2
fi
