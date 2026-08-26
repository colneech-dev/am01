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
