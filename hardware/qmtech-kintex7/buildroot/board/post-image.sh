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
echo "root=/dev/mmcblk0p2 rootwait console=tty1 console=ttyAMA0,115200" \
	> "${BINARIES_DIR}/cmdline.txt"

exec "${HOST_DIR}/bin/genimage" \
	--rootpath "${TARGET_DIR}" \
	--tmppath "${BUILD_DIR}/genimage.tmp" \
	--inputpath "${BINARIES_DIR}" \
	--outputpath "${BINARIES_DIR}" \
	--config "${BOARD_DIR}/genimage.cfg"
