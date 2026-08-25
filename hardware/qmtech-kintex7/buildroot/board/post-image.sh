#!/bin/sh
# Assemble output/images/sdcard.img from the kernel, DTB, Pi firmware and the
# ext4 root. Buildroot runs this after the filesystem images are built.
set -e

BOARD_DIR="$(dirname "$0")"

# cmdline.txt must sit next to the other boot files for genimage to pick it up.
# mmcblk0p2 is the second partition of the eMMC on a CM4.
echo "root=/dev/mmcblk0p2 rootwait console=tty1 console=ttyAMA0,115200" \
	> "${BINARIES_DIR}/cmdline.txt"

exec "${HOST_DIR}/bin/genimage" \
	--rootpath "${TARGET_DIR}" \
	--tmppath "${BUILD_DIR}/genimage.tmp" \
	--inputpath "${BINARIES_DIR}" \
	--outputpath "${BINARIES_DIR}" \
	--config "${BOARD_DIR}/genimage.cfg"
