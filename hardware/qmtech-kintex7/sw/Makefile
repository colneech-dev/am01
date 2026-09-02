# AM01 OdoCrypt Mining Stack — Buildroot Cross-Compile Makefile
#
# Builds the complete AM01 mining stack for Raspberry Pi CM4 + Kintex-7 FPGA:
#   - odo-miner (mining daemon, core)
#   - odo-webd (web dashboard server)
#   - odo-ui (touch screen UI, optional)
#
# Usage:
#   make                                    # Build all binaries
#   make odo-miner                          # Build daemon only
#   make odo-webd                           # Build web server only
#   make odo-ui                             # Build UI only
#   make install DESTDIR=/path/to/rootfs   # Install to overlay
#   make clean                              # Clean artifacts
#
# Assumes odo-miner-cyclonev is at ../../../odo-miner-cyclonev,
# or set ODO_REPO=/path/to/odo-miner-cyclonev before calling make.

# =========================================================================
# Configuration
# =========================================================================

# Location of repositories
ODO_REPO ?= $(abspath ../../../../odo-miner-cyclonev)
ODO_HPS := $(ODO_REPO)/hps
ODO_HDL := $(ODO_REPO)/hdl/odocrypt
ODO_SW := $(ODO_REPO)/sw
ODO_CRYPTO := $(ODO_REPO)/third_party/odo-miner/src/crypto
GPIO_BUS := ../cm4-firmware
# CYD front-panel sources, compiled into the miner (see cyd_panel.h).
CYD_HOST := $(abspath ../cyd/host)

# Installation prefix
PREFIX ?= /usr/local
DESTDIR ?=

# Compiler toolchain (set by Buildroot, or use system defaults)
CC ?= gcc
PKG_CONFIG ?= pkg-config
CFLAGS ?= -O2 -Wall -Wextra -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE
LDFLAGS ?=

# Base compiler flags
# Include paths: local, odo-miner-cyclonev sources, AM01 gpio bus, keccak
# headers, and the stb single-header libs vendored alongside odo-ui.
override CFLAGS += -I. -I$(ODO_HPS) -I$(ODO_HDL) -I$(ODO_CRYPTO) -I$(GPIO_BUS) -I$(CYD_HOST) \
	-I$(ODO_SW)/odo-ui/stb

# Base libraries (for all binaries)
LIBS_BASE := -lpthread

# am01_gpio_bus.c talks to the FPGA through libgpiod
LIBS_MINER := $(LIBS_BASE) $(shell $(PKG_CONFIG) --libs libgpiod 2>/dev/null || echo "-lgpiod")

# =========================================================================
# Object layout
# =========================================================================
#
# Objects are built into OBJ_DIR, never alongside their sources. The sources
# live in sibling repositories (odo-miner-cyclonev, cm4-firmware); writing
# .o files there pollutes those trees, and worse, a stale object from an
# earlier build for a different architecture gets silently reused -- which
# is how an x86-64 odo_webd.o ended up being fed to the aarch64 linker
# ("Relocations in generic ELF (EM: 62)").
#
# Basenames across all source groups are unique, so flattening is safe.
#
# THE SAME TRAP CAUGHT ME AGAIN ON 2026-09-01, in the other direction: obj/
# held aarch64 objects from a cross build, and a native `make` fed them to the
# x86-64 linker ("EM: 183"). Pass OBJ_DIR explicitly for anything but a plain
# native build, and rm -rf the directory if in doubt -- it is cheap.
#
# CROSS-BUILDING FOR THE BOARD. The CM4 image has no compiler, so odo-miner is
# cross-built with the Buildroot toolchain that produced the rootfs:
#
#   BR=~/br-am01/buildroot/output/host
#   make OBJ_DIR=obj-cross CC=$BR/bin/aarch64-buildroot-linux-gnu-gcc #        PKG_CONFIG=$BR/bin/pkg-config odo-miner
#
# It has to be that toolchain rather than a distro aarch64-linux-gnu-gcc:
# am01_gpio_bus.c needs libgpiod, the board ships 1.6.5 (the v1 API), and a
# current distro has 2.x -- which renamed most of the API, so it does not just
# fail to link, it fails to compile. The sysroot at
# $BR/aarch64-buildroot-linux-gnu/sysroot has the matching 1.6.5 headers.

OBJ_DIR ?= obj

objects = $(addprefix $(OBJ_DIR)/,$(notdir $(1:.c=.o)))

# =========================================================================
# Source file groups
# =========================================================================

# Crypto (OdoCrypt + Keccak SHA-3)
SOURCES_CRYPTO := \
	$(ODO_HPS)/odocrypt_state.c \
	$(ODO_HPS)/odocrypt_header.c

SOURCES_KECCAK := \
	$(ODO_CRYPTO)/KeccakP-800-reference.c

# Stratum (pool communication)
SOURCES_STRATUM := \
	$(ODO_HPS)/stratum.c \
	$(ODO_HPS)/job.c

# =====================================================================
# Binary: odo-miner (core mining daemon)
# =====================================================================

# miner_pipe_am01.c is a LOCAL COPY of odo-miner-cyclonev/hps/miner_pipe.c,
# deliberately not built from the sibling repo: that is a separate project
# with different hardware under it, so a fix that is right here is not
# automatically right there. The divergence list is in the file banner.
SOURCES_DAEMON := \
	miner_pipe_am01.c \
	thermal_am01.c \
	$(CYD_HOST)/cyd_panel.c \
	$(CYD_HOST)/cyd_cmd.c \
	miner_io_gpio.c \
	$(GPIO_BUS)/am01_gpio_bus.c \
	$(GPIO_BUS)/am01_panel.c

OBJECTS_DAEMON := $(call objects,$(SOURCES_DAEMON) $(SOURCES_CRYPTO) \
	$(SOURCES_KECCAK) $(SOURCES_STRATUM))

# =====================================================================
# Binary: odo-webd (HTTP status server)
# =====================================================================

SOURCES_WEBD := $(ODO_SW)/odo-webd/odo_webd.c

OBJECTS_WEBD := $(call objects,$(SOURCES_WEBD))

# =====================================================================
# Binary: am01_bus_test (GPIO bus smoke test, no mining)
# =====================================================================

SOURCES_BUSTEST := \
	$(GPIO_BUS)/am01_bus_test.c \
	$(GPIO_BUS)/am01_gpio_bus.c

OBJECTS_BUSTEST := $(call objects,$(SOURCES_BUSTEST))

# =====================================================================
# Binary: am01_diag (reads every FPGA register; no mining, read-only)
# =====================================================================

SOURCES_DIAG := \
	$(GPIO_BUS)/am01_diag.c \
	$(GPIO_BUS)/am01_gpio_bus.c

OBJECTS_DIAG := $(call objects,$(SOURCES_DIAG))

LIBS_WEBD := $(LIBS_BASE)

# =====================================================================
# Binary: am01_busbench (measures bus throughput; no mining, write-only)
#
# Answers whether pushing pixels to the ILI9341 through this bus is viable
# at all, which decides between full-frame blits and damage tracking.
# =====================================================================

SOURCES_BUSBENCH := \
	$(GPIO_BUS)/am01_busbench.c \
	$(GPIO_BUS)/am01_gpio_bus.c

OBJECTS_BUSBENCH := $(call objects,$(SOURCES_BUSBENCH))

# =====================================================================
# Binary: am01_probe (drive fan + panel directly, no miner)
#
# Both were previously reachable only through odo-miner: the panel is pushed
# from the mining loop's idle path, so a screen could not be brought up without
# a working pool, and nothing exposed the fan duty floor at all. Neither is a
# hardware limitation -- just missing tools.
# =====================================================================

SOURCES_PROBE := 	$(GPIO_BUS)/am01_probe.c 	$(GPIO_BUS)/am01_gpio_bus.c

OBJECTS_PROBE := $(call objects,$(SOURCES_PROBE))

# =====================================================================
# Binary: am01_reg (read/write any bus register)
#
# am01_diag prints a curated set. When the register misbehaving is one it
# does not print, the choice was extend-and-redeploy or guess -- and guessing
# is what this project has repeatedly paid for.
# =====================================================================
SOURCES_REG := 	$(GPIO_BUS)/am01_reg.c 	$(GPIO_BUS)/am01_gpio_bus.c

OBJECTS_REG := $(call objects,$(SOURCES_REG))

# =====================================================================
# Binary: am01_smoke (does the FPGA compute the RIGHT hash?)
#
# Dispatches ONE fixed header with a loose target and checks every returned
# nonce against the software oracle. No pool, no job switching, so a failure
# cannot be staleness -- which is the ambiguity odo-miner's "stale" counter
# cannot resolve. Needs the crypto oracle and Keccak, hence the extra groups.
#
# miner_io_gpio.c pulls in am01_panel.c for the cooperative display slice, so
# that comes along even though this tool never draws anything.
# =====================================================================

SOURCES_SMOKE := \
	$(GPIO_BUS)/am01_smoke.c \
	miner_io_gpio.c \
	$(GPIO_BUS)/am01_gpio_bus.c \
	$(GPIO_BUS)/am01_panel.c

OBJECTS_SMOKE := $(call objects,$(SOURCES_SMOKE) $(SOURCES_CRYPTO) \
	$(SOURCES_KECCAK))

# =====================================================================
# Binary: odo-ui (touch screen UI, optional)
# =====================================================================

SOURCES_UI := \
	$(ODO_SW)/odo-ui/odo_ui.c \
	$(ODO_SW)/odo-ui/odoui_gfx.c

OBJECTS_UI := $(call objects,$(SOURCES_UI))

# UI needs: libpng, freetype2, fontconfig for font/image rendering
override CFLAGS += $(shell $(PKG_CONFIG) --cflags libgpiod libpng freetype2 fontconfig 2>/dev/null || echo "")
# -lm: stb_truetype's rasteriser pulls in sqrt()
LIBS_UI := $(LIBS_BASE) $(shell $(PKG_CONFIG) --libs libpng freetype2 fontconfig 2>/dev/null || echo "-lpng -lfreetype -lfontconfig") -lm

# =====================================================================
# Targets
# =====================================================================

.PHONY: all clean install help
.PHONY: odo-miner odo-webd odo-ui am01_bus_test am01_diag am01_busbench am01_smoke am01_probe am01_reg

# Default: build all. am01_bus_test is included deliberately -- it is the
# first thing to run on a new board (see ../cm4-firmware/README.md), so it
# needs to be in the image rather than something to compile on the target.
all: odo-miner odo-webd odo-ui am01_bus_test am01_diag am01_busbench am01_smoke am01_probe am01_reg

# Mining daemon (core)
odo-miner: $(OBJECTS_DAEMON)
	@echo "[LD] $@"
	$(CC) $(LDFLAGS) -o $@ $^ $(LIBS_MINER)
	@echo "✓ Built: $@"

# Web status server
odo-webd: $(OBJECTS_WEBD)
	@echo "[LD] $@"
	$(CC) $(LDFLAGS) -o $@ $^ $(LIBS_WEBD)
	@echo "✓ Built: $@"

# Bus smoke test: reads STATUS/VERSION, submits a dummy work item, waits for
# an IRQ. Proves the GPIO bus round-trips before the miner is involved.
am01_bus_test: $(OBJECTS_BUSTEST)
	@echo "[LD] $@"
	$(CC) $(LDFLAGS) -o $@ $^ $(LIBS_MINER)
	@echo "✓ Built: $@"

# Read-only register dump: VERSION, epoch seed, die temp, rails, fan.
am01_diag: $(OBJECTS_DIAG)
	@echo "[LD] $@"
	$(CC) $(LDFLAGS) -o $@ $^ $(LIBS_MINER) -lm
	@echo "✓ Built: $@"

# Bus throughput benchmark. Uses -lm for the fps/timing arithmetic.
am01_busbench: $(OBJECTS_BUSBENCH)
	@echo "[LD] $@"
	$(CC) $(LDFLAGS) -o $@ $^ $(LIBS_MINER) -lm
	@echo "✓ Built: $@"

# Hash-correctness check against the software oracle. -lm for the rate
# arithmetic, same as am01_diag.
am01_smoke: $(OBJECTS_SMOKE)
	@echo "[LD] $@"
	$(CC) $(LDFLAGS) -o $@ $^ $(LIBS_MINER) -lm
	@echo "✓ Built: $@"

# Direct fan/panel probe. No crypto, no miner -- just the bus.
am01_probe: $(OBJECTS_PROBE)
	@echo "[LD] $@"
	$(CC) $(LDFLAGS) -o $@ $^ $(LIBS_MINER)
	@echo "✓ Built: $@"

# Raw register access, for when a typed accessor is the wrong tool.
am01_reg: $(OBJECTS_REG)
	@echo "[LD] $@"
	$(CC) $(LDFLAGS) -o $@ $^ $(LIBS_MINER)
	@echo "✓ Built: $@"

# Touch UI (framebuffer + touch input)
odo-ui: $(OBJECTS_UI)
	@echo "[LD] $@"
	$(CC) $(LDFLAGS) -o $@ $^ $(LIBS_UI)
	@echo "✓ Built: $@"

# Let make find the sources by basename, wherever they live.
ALL_SOURCES := $(SOURCES_DAEMON) $(SOURCES_CRYPTO) $(SOURCES_KECCAK) \
	$(SOURCES_BUSBENCH) \
	$(SOURCES_STRATUM) $(SOURCES_WEBD) $(SOURCES_UI) $(SOURCES_BUSTEST) \
	$(SOURCES_DIAG) $(SOURCES_SMOKE) $(SOURCES_PROBE)
vpath %.c $(sort $(dir $(ALL_SOURCES)))

$(OBJ_DIR):
	@mkdir -p $@

$(OBJ_DIR)/%.o: %.c | $(OBJ_DIR)
	@echo "[CC] $<"
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f odo-miner odo-webd odo-ui am01_bus_test am01_diag am01_busbench am01_smoke am01_probe
	rm -rf $(OBJ_DIR)
	@echo "Cleaned."

# Install binaries to rootfs overlay
install: all
	install -D -m 0755 odo-miner $(DESTDIR)$(PREFIX)/bin/odo-miner
	install -D -m 0755 odo-webd $(DESTDIR)$(PREFIX)/bin/odo-webd
	install -D -m 0755 odo-ui $(DESTDIR)$(PREFIX)/bin/odo-ui
	install -D -m 0755 am01_bus_test $(DESTDIR)$(PREFIX)/bin/am01_bus_test
	install -D -m 0755 am01_diag $(DESTDIR)$(PREFIX)/bin/am01_diag
	install -D -m 0755 am01_busbench $(DESTDIR)$(PREFIX)/bin/am01_busbench
	install -D -m 0755 am01_smoke $(DESTDIR)$(PREFIX)/bin/am01_smoke
	install -D -m 0755 am01_probe $(DESTDIR)$(PREFIX)/bin/am01_probe
	install -D -m 0755 am01_reg $(DESTDIR)$(PREFIX)/bin/am01_reg
	@echo "✓ Installed binaries to $(DESTDIR)$(PREFIX)/bin/"

# Help
help:
	@echo "AM01 Mining Stack Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all               Build all binaries (odo-miner, odo-webd, odo-ui)"
	@echo "  odo-miner         Mining daemon (GPU I/O)"
	@echo "  odo-webd          Web dashboard HTTP server"
	@echo "  odo-ui            Touch UI (requires framebuffer + touch driver)"
	@echo "  install           Install to DESTDIR+PREFIX"
	@echo "  clean             Remove build artifacts"
	@echo ""
	@echo "Variables:"
	@echo "  ODO_REPO          Path to odo-miner-cyclonev"
	@echo "  PREFIX            Install prefix (default /usr/local)"
	@echo "  DESTDIR           Root for installation (cross-compile)"
	@echo ""
	@echo "Dependencies:"
	@echo "  odo-miner:  libpthread, libgpiod"
	@echo "  odo-webd:   libpthread"
	@echo "  odo-ui:     libpng, freetype2, fontconfig, framebuffer, touch driver"
