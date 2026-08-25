#!/bin/sh
# Runs after the rootfs overlay has been copied, which is why the WiFi
# credential file cannot be chmod'ed from the package -- packages install
# before overlays are applied.
set -e

WPA="${TARGET_DIR}/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"

# The file is gitignored because it holds a credential, so a fresh clone will
# not have it. Missing means "no WiFi configured", not a build failure.
if [ -f "$WPA" ]; then
	chmod 0600 "$WPA"
else
	echo "post-build: no wpa_supplicant-wlan0.conf; WiFi will not associate." >&2
fi
