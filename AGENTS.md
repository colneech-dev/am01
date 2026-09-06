# AM01 Project Context & System Architecture Guide (for AI Assistants)

## 1. Project Overview & Identity

**AM01** is a high-performance, open-source FPGA cryptocurrency miner implementation targeting the **Odocrypt** algorithm on a **QMTECH Xilinx Kintex-7 (XC7K325T-2FFG676C)** development board paired with a **Raspberry Pi Compute Module 4 (CM4)** and an optional **CYD (Cheap Yellow Display, ESP32-2432S028R)** touchscreen front panel.

### Key Hardware Specifications
- **FPGA**: Xilinx Kintex-7 XC7K325T (890 RAMB18 blocks, 203,800 LUTs, 407,600 Flip-Flops).
- **Host Carrier**: Raspberry Pi CM4 (runs Linux, Stratum daemon `miner_pipe_am01`, web dashboard `odo-webd`).
- **Host-FPGA Interconnect**: 24-line parallel GPIO bus with 16-bit data beats, asynchronous handshake (`gpio_wr_n`, `gpio_rd_n`, `gpio_ready`, `gpio_irq`).
- **Front Panel**: ESP32-2432S028R ("CYD") connected via 115200-baud UART on dedicated FPGA header pins (JP5 pins 15–18).

---

## 2. Directory Structure & Key Files

```
am01/
├── AGENTS.md                                 # This document
├── BUILD_AM01.sh                             # Full system build script
├── SETUP_BUILD_ENV.md                        # Toolchain setup instructions
├── hdl/
│   └── odocrypt/                             # Core cipher HDL (epoch-dependent)
│       ├── encrypt.v                         # Pipelined Odocrypt round stages
│       ├── keccak800.v                       # Keccak-800 permutation logic
│       ├── miner_pipelined.v                 # Free-running pipelined miner core (v2.0+)
│       └── miner_t3.v                        # Throughput-3 optimized core variant
├── hardware/
│   └── qmtech-kintex7/
│       ├── hdl/                              # Board-level HDL & bus wrapper
│       │   ├── am01_qmtech_top.v             # Top-level module (clocking, IBUF, pins)
│       │   ├── clk_gen_hash.v                # MMCM clock synthesizer (clk_h, clk_2x)
│       │   ├── odocrypt_gpio_wrapper.v       # 16-bit GPIO bus interface & register map
│       │   ├── found_path.v                  # Settle window, found-FIFO & CDC handoff
│       │   ├── sbox_large_mux2.v             # Dual-port time-multiplexed S-box BRAMs
│       │   └── uart_bridge.v                 # UART bridge for CYD front panel
│       ├── xdc/
│       │   └── qmtech_xc7k325t_pinout.xdc    # Physical pin & timing constraints
│       ├── sw/                               # Host software (C / Linux)
│       │   ├── miner_pipe_am01.c             # Stratum mining daemon
│       │   ├── miner_io_gpio.c               # libgpiod parallel bus transport layer
│       │   ├── thermal_am01.c                # Fan PID, XADC supply rail telemetry
│       │   └── webd/odo_webd_am01.c          # Embedded HTTP server / dashboard
│       ├── cyd/firmware/                     # ESP32 Touchscreen Firmware (C/C++)
│       │   ├── src/main.cpp                  # Entrypoint, FreeRTOS loop, NVS settings
│       │   ├── src/cyd_ui.c                  # UI state machine & event handlers
│       │   ├── src/cyd_ui_draw.cpp           # Banded TFT_eSPI graphics renderer
│       │   ├── src/cyd_link_uart.cpp         # Serial link communication
│       │   └── src/cyd_status_parse.c        # Status JSON stream parser
│       ├── openxc7/                          # Open-source EDA flow (Yosys + nextpnr)
│       │   ├── floorplan_stripe.py           # BRAM column partitioning
│       │   └── absorb_bram_outreg.py         # Register-to-BRAM absorption
│       └── sim/                              # Icarus Verilog simulation testbenches
│           ├── tb_found_path.v               # Found path & CDC testbench
│           └── run_sched_equiv.sh            # Equivalence verification scripts
└── tools/
    ├── odo_gen/                              # C++ Odocrypt cipher & HDL generator
    └── check-epoch.sh                        # Epoch staleness validator
```

---

## 3. Core Architectural Concepts & Invariants

### 3.1 FPGA Pipeline & Nonce Tracking (v2.0+)
- **Free-Running Architecture**: Unlike legacy halt-on-find cores (`miner.v`), `miner_pipelined.v` free-runs from power-on.
- **Strict Invariant**: `nonce_in` increments on each `advance` pulse, and `nonce_out` increments on each `has_res` strobe. The $N$-th result strictly corresponds to the $N$-th nonce.
- **Never Re-Arm on v2.0+**: Flashing bitstream version $\ge 0x0200$ means the core never halts on a find. The host must **not** re-dispatch/re-arm on a find; doing so reopens the 4096-cycle settle window and discards valid nonces.

### 3.2 Found Path, FIFO & Clock Domain Crossing (`found_path.v`)
- **Settle Suppression Window**: Holds `report_ok` low for 4096 cycles after `commit` to prevent in-flight pipeline residue from qualifying against a new header.
- **Two-Phase Handoff**: Crosses domain from `clk_h` (hash clock) to `bus_clk` (GPIO bus) using `ack_toggle` and `nonce_toggle` with `(* ASYNC_REG = "TRUE" *)` synchronizers.
- **Soft Reset**: Asserting `CTRL[0]` (`OP_SOFT_RESET`) clears `busy` and resets FIFO read/write pointers to recover from unacknowledged handoffs if the host process terminates mid-read.

### 3.3 Stratum Daemon Job Accounting (`miner_pipe_am01.c`)
- **`cur` vs `disp` Jobs**:
  - `cur`: The latest job received from Stratum.
  - `disp`: The job currently committed to FPGA hardware.
  - Finds drained from the FIFO are **always** validated and submitted against `disp.header`.
- **Handover Drain Window**: When a new job arrives, `disp` is saved to `prev`, the new job is written to the FPGA, and a fast drain loop (`miner_io_pipe_poll`) immediately drains and validates any nonces found against `prev` during the dispatch window, submitting them as `(handover)` shares.

### 3.4 Host Thread Safety & Bus Resource Lifecycle
- `g_therm_mu` guards temperature (`temp_c`), voltages (`vccint`, `vccaux`, `vccbram`), and fan speed between `thermal_thread` and `status_write()`.
- **Destruction Order**: On clean exit or `SIGINT`/`SIGTERM`:
  1. Call `cyd_panel_stop()`.
  2. Call `pthread_join(therm_tid, NULL)`.
  3. Call `miner_io_pipe_shutdown()` (closes `am01_bus_close()` and frees mutex).
  *Violating this sequence causes an immediate use-after-free on `am01_bus_t`.*

### 3.5 CYD Front Panel Banded Rendering Engine
- The ESP32 heap has a maximum contiguous block limit of ~110 KB. A full 320x240 16-bpp canvas requires 153.6 KB.
- `cyd_ui_draw.cpp` renders in horizontal sub-screen bands (`Gfx` struct with `yoff`), pushing bands sequentially to `TFT_eSPI` to avoid heap fragmentation and out-of-memory crashes.

### 3.6 Privilege Separation & Web Daemon Security (`odo-webd`)
- `odo-webd` runs unprivileged as `User=miner`.
- Mutating actions (`/config`, `/wifi`) write atomic dot-prefixed request files (`/run/odod/request/.verb.tmp`) and rename them to `/run/odod/request/verb`.
- The root daemon `am01-panel-helper` watches this directory via systemd path units, validates inputs against strict allow-lists, and applies changes.

---

## 4. Build, Simulation & Verification Workflows

### 4.1 Building Host Software
```bash
cd hardware/qmtech-kintex7/sw
make clean && make -j$(nproc)
```
Produces:
- `odo-miner-pipe`: Mining daemon.
- `odo-webd`: Web dashboard and control server.

### 4.2 Building CYD Firmware (PlatformIO)
```bash
cd hardware/qmtech-kintex7/cyd/firmware
pio run -e esp32dev
```

### 4.3 Running RTL Simulation & Equivalence Tests
```bash
cd hardware/qmtech-kintex7/sim
./run_sched_equiv.sh
./run_lutram_equiv.sh
```

### 4.4 Checking Odocrypt Epoch Staleness
```bash
./tools/check-epoch.sh
```

---

## 5. Key Rules & Coding Conventions for AI Contributors

1. **JSON String Escaping**: Whenever writing JSON in C (`status_write()`, `odo_webd`), always route untrusted strings (e.g., SSIDs, worker names, job IDs) through `json_str()` or `json_escape()` to escape quotes (`"`) and backslashes (`\`).
2. **Buffer Offsets**: Never advance buffer offsets directly using raw `snprintf()` return values. Use `off_after_snprintf()` to prevent out-of-bounds reads if format strings exceed capacity.
3. **No Dynamic Allocation in Hot Paths**: Keep FIFO draining, stratum polling, and band rendering strictly static/stack allocated.
4. **Preserve Comments**: Maintain all hardware errata documentation and timing notes across HDL and C sources.
