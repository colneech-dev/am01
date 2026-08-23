#!/bin/bash
# AM01 Mining Stack - Complete Build Script
#
# This script builds the entire AM01 mining stack for Raspberry Pi CM4.
# Requires: Linux (native, WSL, or VM), Buildroot, ~15GB disk space, ~30 min time
#
# Usage:
#   ./BUILD_AM01.sh                 # Interactive: choose what to build
#   ./BUILD_AM01.sh all             # Build daemon + web + ui
#   ./BUILD_AM01.sh daemon          # Build daemon only
#   ./BUILD_AM01.sh buildroot       # Full Buildroot image
#
# Prerequisites (install on Linux):
#   sudo apt-get install -y build-essential libncurses-dev git wget bc unzip
#   # Clone Buildroot:
#   git clone https://git.buildroot.net/buildroot buildroot
#   cd buildroot && git checkout 2025.01  # or latest stable

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
AM01_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODO_REPO="${AM01_REPO}/../../odo-miner-cyclonev"
BUILDROOT_DIR="${BUILDROOT_DIR:-${AM01_REPO}/../../buildroot}"
BUILD_CORES="${BUILD_CORES:-3}"
PREFIX="${PREFIX:-/usr/local}"

echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  AM01 Mining Stack Build Script                       ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

# Helper functions
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Check prerequisites
check_prereqs() {
    log_info "Checking prerequisites..."

    # Check if running on Linux
    if [[ ! "$OSTYPE" =~ linux-gnu ]]; then
        log_err "This script must run on Linux (native, WSL, or VM)"
    fi

    # Check for required tools
    for tool in gcc make git pkg-config; do
        if ! command -v $tool &> /dev/null; then
            log_err "$tool not found. Install with: sudo apt-get install build-essential"
        fi
    done

    # Check for odo-miner-cyclonev
    if [ ! -f "$ODO_REPO/hps/miner_pipe.c" ]; then
        log_warn "odo-miner-cyclonev not found at $ODO_REPO"
        log_warn "Clone it: git clone https://github.com/colneech-dev/odo-miner-cyclonev"
        read -p "Continue anyway? (y/n) " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi

    log_info "✓ Prerequisites OK"
}

# Build mining daemon (odo-miner)
build_daemon() {
    log_info "Building mining daemon (odo-miner)..."
    cd "$AM01_REPO/hardware/qmtech-kintex7/sw"

    make clean
    make -j${BUILD_CORES} odo-miner

    log_info "✓ odo-miner built successfully"
    ls -lh odo-miner
}

# Build web server (odo-webd)
build_webd() {
    log_info "Building web server (odo-webd)..."
    cd "$AM01_REPO/hardware/qmtech-kintex7/sw"

    make -j${BUILD_CORES} odo-webd

    log_info "✓ odo-webd built successfully"
    ls -lh odo-webd
}

# Build touch UI (odo-ui)
build_ui() {
    log_info "Building touch UI (odo-ui)..."
    cd "$AM01_REPO/hardware/qmtech-kintex7/sw"

    make -j${BUILD_CORES} odo-ui

    log_info "✓ odo-ui built successfully"
    ls -lh odo-ui
}

# Full Buildroot build
build_buildroot() {
    log_info "Building Buildroot image for CM4..."

    if [ ! -d "$BUILDROOT_DIR" ]; then
        log_err "Buildroot not found at $BUILDROOT_DIR"
        echo "Clone it: git clone https://git.buildroot.net/buildroot $BUILDROOT_DIR"
        exit 1
    fi

    cd "$BUILDROOT_DIR"

    log_info "Configuring Buildroot..."
    # BR2_EXTERNAL supplies the odo-mining-stack package; without it the image
    # builds with no mining binaries in it.
    make BR2_EXTERNAL="$AM01_REPO/hardware/qmtech-kintex7/buildroot" \
        defconfig BR2_DEFCONFIG="$AM01_REPO/hardware/qmtech-kintex7/linux/buildroot_cm4_defconfig"

    log_info "Building (a full aarch64 toolchain from scratch takes hours)..."
    make -j${BUILD_CORES}

    log_info "✓ Buildroot image complete"
    log_info "Output at: $BUILDROOT_DIR/output/images/"
    ls -lh "$BUILDROOT_DIR/output/images/" | grep -E "rootfs|Image|dtb"
}

# Install binaries to a target directory
install_binaries() {
    local target_dir="$1"

    if [ -z "$target_dir" ]; then
        log_err "No target directory specified"
    fi

    log_info "Installing binaries to $target_dir..."
    cd "$AM01_REPO/hardware/qmtech-kintex7/sw"

    mkdir -p "$target_dir$PREFIX/bin"
    install -D -m 0755 odo-miner "$target_dir$PREFIX/bin/odo-miner"
    install -D -m 0755 odo-webd "$target_dir$PREFIX/bin/odo-webd"
    install -D -m 0755 odo-ui "$target_dir$PREFIX/bin/odo-ui"

    log_info "✓ Binaries installed"
    ls -lh "$target_dir$PREFIX/bin/"
}

# Show usage
show_usage() {
    cat << EOF
Usage: $(basename "$0") [COMMAND]

Commands:
  all               Build all binaries (daemon, web, ui)
  daemon            Build mining daemon only
  webd              Build web server only
  ui                Build touch UI only
  buildroot         Full Buildroot image (includes all binaries)
  install TARGET    Install binaries to TARGET directory
  interactive       Choose what to build (default)

Examples:
  ./BUILD_AM01.sh all
  ./BUILD_AM01.sh buildroot
  ./BUILD_AM01.sh install /mnt/rootfs

Environment Variables:
  BUILD_CORES       Number of parallel make jobs (default: 3)
  BUILDROOT_DIR     Path to Buildroot directory
  ODO_REPO          Path to odo-miner-cyclonev

EOF
}

# Main
main() {
    check_prereqs

    local cmd="${1:-interactive}"

    case "$cmd" in
        all)
            build_daemon
            build_webd
            build_ui
            log_info "✓ All binaries built successfully"
            ;;
        daemon)
            build_daemon
            ;;
        webd)
            build_webd
            ;;
        ui)
            build_ui
            ;;
        buildroot)
            build_buildroot
            ;;
        install)
            build_daemon build_webd build_ui
            install_binaries "$2"
            ;;
        -h|--help|help)
            show_usage
            exit 0
            ;;
        interactive)
            echo "What would you like to build?"
            echo "1) Mining daemon only (odo-miner)"
            echo "2) Web server (odo-webd)"
            echo "3) Touch UI (odo-ui)"
            echo "4) All binaries (daemon + web + ui)"
            echo "5) Full Buildroot image (everything)"
            read -p "Choose [1-5]: " choice

            case $choice in
                1) build_daemon ;;
                2) build_webd ;;
                3) build_ui ;;
                4) build_daemon; build_webd; build_ui ;;
                5) build_buildroot ;;
                *) log_err "Invalid choice" ;;
            esac
            ;;
        *)
            log_err "Unknown command: $cmd"
            show_usage
            exit 1
            ;;
    esac

    echo ""
    log_info "Build complete! 🎉"
}

main "$@"
