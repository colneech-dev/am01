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
override CFLAGS += -I. -I$(ODO_HPS) -I$(ODO_HDL) -I$(ODO_CRYPTO) -I$(GPIO_BUS) \
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

SOURCES_DAEMON := \
	$(ODO_HPS)/miner_pipe.c \
	$(ODO_HPS)/thermal.c \
	miner_io_gpio.c \
	$(GPIO_BUS)/am01_gpio_bus.c

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
.PHONY: odo-miner odo-webd odo-ui am01_bus_test am01_diag

# Default: build all. am01_bus_test is included deliberately -- it is the
# first thing to run on a new board (see ../cm4-firmware/README.md), so it
# needs to be in the image rather than something to compile on the target.
all: odo-miner odo-webd odo-ui am01_bus_test am01_diag

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

# Touch UI (framebuffer + touch input)
odo-ui: $(OBJECTS_UI)
	@echo "[LD] $@"
	$(CC) $(LDFLAGS) -o $@ $^ $(LIBS_UI)
	@echo "✓ Built: $@"

# Let make find the sources by basename, wherever they live.
ALL_SOURCES := $(SOURCES_DAEMON) $(SOURCES_CRYPTO) $(SOURCES_KECCAK) \
	$(SOURCES_STRATUM) $(SOURCES_WEBD) $(SOURCES_UI) $(SOURCES_BUSTEST) \
	$(SOURCES_DIAG)
vpath %.c $(sort $(dir $(ALL_SOURCES)))

$(OBJ_DIR):
	@mkdir -p $@

$(OBJ_DIR)/%.o: %.c | $(OBJ_DIR)
	@echo "[CC] $<"
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f odo-miner odo-webd odo-ui am01_bus_test am01_diag
	rm -rf $(OBJ_DIR)
	@echo "Cleaned."

# Install binaries to rootfs overlay
install: all
	install -D -m 0755 odo-miner $(DESTDIR)$(PREFIX)/bin/odo-miner
	install -D -m 0755 odo-webd $(DESTDIR)$(PREFIX)/bin/odo-webd
	install -D -m 0755 odo-ui $(DESTDIR)$(PREFIX)/bin/odo-ui
	install -D -m 0755 am01_bus_test $(DESTDIR)$(PREFIX)/bin/am01_bus_test
	install -D -m 0755 am01_diag $(DESTDIR)$(PREFIX)/bin/am01_diag
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
