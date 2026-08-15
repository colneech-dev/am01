#!/usr/bin/env bash
# One-shot provisioning for the CM4 side of the AM01 QMTECH miner.
#
# Run this once after first SSH login to a freshly-flashed Raspberry Pi OS
# Lite install:
#
#   curl -fsSL https://raw.githubusercontent.com/colneech-dev/am01/claude/sbox-mux2-integration/hardware/qmtech-kintex7/cm4-firmware/setup-pi.sh | bash
#
# or, if you've already cloned the repo:
#
#   bash hardware/qmtech-kintex7/cm4-firmware/setup-pi.sh
#
# What this does:
#   1. System update
#   2. Install build deps for cm4-firmware (libgpiod) and openFPGALoader
#      (JTAG programming over a USB-JTAG adapter -- see the README's note
#      on why direct CM4-GPIO-to-J1 wiring isn't viable on this board)
#   3. Clone/update this repo
#   4. Build cm4-firmware (am01_bus_test)
#   5. Build and install openFPGALoader from source, plus its udev rules
#      so USB-JTAG adapters work without sudo
#
# What it deliberately does NOT do: touch the FPGA. There's nothing to
# program yet -- see the top-level README's "what's still needed" list.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/colneech-dev/am01.git}"
REPO_DIR="${REPO_DIR:-$HOME/am01}"

echo "==> [1/5] system update"
sudo apt update
sudo apt full-upgrade -y

echo "==> [2/5] packages"
sudo apt install -y \
    git build-essential cmake pkg-config \
    libgpiod-dev gpiod \
    libftdi1-dev libusb-1.0-0-dev libhidapi-dev libudev-dev \
    zlib1g-dev

echo "==> [3/5] clone/update am01"
if [ ! -d "$REPO_DIR/.git" ]; then
    git clone "$REPO_URL" "$REPO_DIR"
else
    git -C "$REPO_DIR" pull
fi

echo "==> [4/5] build cm4-firmware (am01_bus_test)"
make -C "$REPO_DIR/hardware/qmtech-kintex7/cm4-firmware"

echo "==> [5/5] build + install openFPGALoader (for JTAG programming via a USB-JTAG adapter)"
if ! command -v openFPGALoader >/dev/null 2>&1; then
    OFL_DIR="$HOME/openFPGALoader"
    if [ ! -d "$OFL_DIR" ]; then
        git clone --recursive https://github.com/trabucayre/openFPGALoader.git "$OFL_DIR"
    fi
    mkdir -p "$OFL_DIR/build" && cd "$OFL_DIR/build"
    cmake ..
    make -j"$(nproc)"
    sudo make install
    sudo ldconfig
    # udev rules so a plugged-in USB-JTAG adapter is usable without sudo
    if [ -f "$OFL_DIR/99-openfpgaloader.rules" ]; then
        sudo cp "$OFL_DIR/99-openfpgaloader.rules" /etc/udev/rules.d/
        sudo udevadm control --reload-rules
        sudo udevadm trigger
    fi
else
    echo "    openFPGALoader already installed ($(command -v openFPGALoader)), skipping build"
fi

cat <<'EOF'

==> Done. Next steps:

  1. Cross-check GPIO line numbering before trusting anything:
       gpioinfo
     ...against the table in hardware/qmtech-kintex7/README.md. The
     driver's DATA_OFFSETS/ADDR_OFFSETS/etc. assume gpiochip line offset
     == the GPIOn number 1:1 -- verify, don't assume.

  2. Smoke-test the bus driver (will NOT fully succeed yet -- the FPGA
     has no bitstream loaded, so this just proves the CM4 side works):
       cd hardware/qmtech-kintex7/cm4-firmware
       sudo ./am01_bus_test

  3. Once you have a USB-JTAG adapter wired to the board's J1 header:
       openFPGALoader --help
       openFPGALoader --detect          # confirms the adapter + FPGA are seen
     (Programming command itself comes once there's an actual .bit to load.)
EOF
