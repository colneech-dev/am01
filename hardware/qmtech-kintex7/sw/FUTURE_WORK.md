# AM01 Mining Stack — Future Work & TODOs

## Epoch Update Tool (odo-update) — REQUIRED FOR PRODUCTION

### Status
**NOT YET IMPLEMENTED** for AM01, but no longer blocked: the SEED register
exists, so the mismatch is now detectable on the board. Needs a bitstream
built with it before the watcher can be tested.

Note AM01 is better placed than the Cyclone V here. `epoch-update.sh` there
stages a bitstream and reboots, because runtime FPGA-manager reconfiguration
is unavailable on that kernel. This image ships openFPGALoader and
am01-fpga.service, so a JTAG reload in place needs no reboot.

### What It Does
- Detects when OdoCrypt epoch changes. NOT by wall clock: the epoch derives
  from the chain's block time, so on a slow chain a wall-clock predictor fires
  early or late. The trigger is `job epoch != bitstream_epoch`, both of which
  the daemon now writes to status.json (the SEED register makes the second one
  real rather than a hardcoded 0).
- Swaps FPGA bitstream to one compiled for the new epoch
- Reboots the system to load the new bitstream
- Prevents mining stale epoch (which pool rejects)

### odo-miner-cyclonev Implementation
On Cyclone V HPS:
```bash
usr/sbin/epoch-update.sh          # Shell script runner
services/epoch-update.conf        # Systemd timer (5-min check)
boot/fpga.rbf / fpga_next.rbf    # Current + next bitstream slots
```

Workflow:
1. Daemon detects `job.epoch != SEED` mismatch
2. Checks if `/boot/fpga_next.rbf` exists (pre-staged by offline build)
3. Swaps it into `/boot/fpga.rbf`
4. Reboots via `reboot()`
5. Bootloader loads new bitstream on next boot

### For AM01 + CM4
Need to implement:

1. **Bitstream Storage**
   - `/boot/fpga.rbf` (current, loaded at boot)
   - `/boot/fpga_next.rbf` (staged for next epoch)
   - Both must be on CM4's boot partition (FAT, accessible from firmware)

2. **Epoch Update Script**
   - Check `job.epoch` vs daemon's read of SEED register
   - If mismatch: swap RBF files + reboot
   - Could use cron or systemd timer

3. **Offline Epoch Compilation**
   - Pre-compile bitstreams for future epochs
   - Store on the board or deploy via SSH
   - Current: manual; future: automated CI/CD

4. **JTAG/SPI Programmer** (Optional but Safer)
   - Instead of RBF boot reload, use on-board programmer
   - Preserves boot sector integrity
   - Requires: USB-JTAG adapter + OpenOCD

### Implementation Priority
- **Phase 1 (MVP):** Shell script + RBF swap + reboot
- **Phase 2 (Production):** JTAG auto-program + epoch pre-staging
- **Phase 3 (Hardened):** Dual-bank bitstream slots (A/B boot, avoid bad state)

### Estimated Effort
- Phase 1: 4-6 hours (shell script + testing)
- Phase 2: 8-12 hours (JTAG integration + validation)
- Phase 3: 16-20 hours (redundant boot + failsafe logic)

### References
- odo-miner-cyclonev: `docs/TODO.md`, `usr/sbin/epoch-update.sh`
- AM01 Vivado: `hardware/qmtech-kintex7/hdl/am01_qmtech_top.v` (MMCM clocking setup)
- OpenXC7: `openxc7/` directory for alternate bitstream toolchain (once matured)

---

## Display Support (odo-ui) — OPTIONAL, HARDWARE-DEPENDENT

### Status
**COMPILED** but NOT TESTED on CM4 + actual display.

### What It Needs
- Framebuffer device (`/dev/fb0`) — HDMI, LCD over GPIO, or SPI parallel display
- Touch input device (`/dev/input/eventN`) — XPT2046, capacitive, or GPIO buttons
- libpng, freetype2, fontconfig — already in Buildroot defconfig
- Kernel framebuffer driver — usually built-in for HDMI; custom for parallel LCD

### Display Options for CM4

| Display Type | Interface | Kernel Driver | Notes |
|---|---|---|---|
| HDMI | HDMI port | `vc4_drm` | Standard; uses /dev/fb0 |
| Parallel LCD | GPIO 0-27 | gpio-lcd / custom | Slow (~8MHz), suitable for status view |
| SPI LCD (ILI9341) | SPI0/SPI1 | `fbtft` + `fb_ili9341` | Fast (~50MHz), 320x240 typical |
| USB Display | USB | `udlfb` | External via USB hub |

### Touchscreen Options

| Touchscreen | Interface | Driver | Notes |
|---|---|---|---|
| XPT2046 | SPI + GPIO IRQ | `ads7846` | Common, cheap; capacitive |
| FT6236 | I2C + GPIO IRQ | `focaltech` | Capacitive; robust |
| GPIO Buttons | GPIO pins | `gpio-keys` | Fallback if no touch; manual (up/down/enter) |

### Testing Checklist
- [ ] Framebuffer device exists and works: `cat /dev/urandom > /dev/fb0`
- [ ] Touch input detected: `evtest /dev/input/event0`
- [ ] odo-ui starts without segfault: systemctl status odo-ui
- [ ] UI is responsive to touch
- [ ] Display updates on new shares (lag < 1s)

### Common Issues
- **No `/dev/fb0`** — framebuffer driver not loaded; check kernel config + device-tree
- **Touch not responding** — wrong device path; check `ls -la /dev/input/` or calibrate with `ts_calibrate`
- **Display corruption** — memory layout mismatch; verify resolution in kernel config
- **odo-ui crashes** — font/image loading error; check `/usr/share/fonts/` and overlay assets

### Future: GPU Acceleration
- Current odo-ui uses software rendering (freetype2 + CPU)
- Could accelerate with VC4 GPU (Broadcom VideoCore IV on CM4)
- Would require `libEGL` + framebuffer extensions
- Not urgent for status display; consider if performance is an issue

---

## Web Server (odo-webd) — ALREADY WORKING

### Status
**IMPLEMENTED** and integrated into systemd.

### What It Does
- Serves status JSON at `http://BOARD_IP:8080/status.json`
- Optional: static HTML dashboard for browser viewing
- Reads daemon's status file (`/run/odod/status.json`)

### No Changes Needed
- Compiles as-is from odo-miner-cyclonev
- Works over Ethernet or WiFi (if configured)
- Access from any browser on the LAN

### Optional Enhancements
- Add HTTP API for remote control (pool change, reboot, etc.)
- Add SSL/TLS (self-signed cert)
- Add authentication (basic auth or token)
- Static HTML UI (hosted frontend, not framebuffer)

---

## GPIO I/O Poll and IRQ — DONE (was a correctness bug, not an optimization)

### Status
**FIXED.** This entry previously read "NICE-TO-HAVE / WORKING but not
optimized". That was wrong on both counts.

### What was actually wrong
`miner_io_pipe_poll()` returned 0 ("nonce read") unconditionally, so the
daemon believed a nonce was waiting on every call and validated a garbage
value each pass of its loop. Worse, reading NONCE_HI is what clears
NONCE_VALID and drops the IRQ, so each spurious poll also consumed the flag.
`miner_pipe.c` validates nonces against the current job, so no invalid shares
would have been submitted -- but the miner would have spun at full CPU.

`miner_io_pipe_wait()` slept 5ms and always reported a timeout, on a comment
claiming this backend had no interrupt. GPIO23 *is* the FPGA's nonce-ready
IRQ and `am01_bus_wait_irq()` already existed, requested for both-edge events.

### Fix
- `poll()` reads STATUS and returns 1 when NONCE_VALID is clear, without
  touching NONCE_HI.
- `wait()` blocks on the IRQ edge; a timeout returns 1 and is not an error.
- `miner_io_pipe_version()` reads the real VERSION register rather than a
  hardcoded constant.

---

## Seed Register Exposure — DONE

### Status
**IMPLEMENTED.** SEED_LO/SEED_HI at 0x9/0xA, interface VERSION bumped to
0x0101, fed by the wrapper's ODO_SEED parameter.

### Why it mattered more than "MINOR BUG FIX" suggested
With the seed hardcoded to 0, the daemon's staleness check (`job epoch !=
seed`) fired on every job. A permanently-tripped alarm is the same as no
alarm, so a stale bitstream was undetectable on the board.

### Also added
- `am01_bus_read_seed()` gates on VERSION and returns ENOTSUP against an
  older bitstream, because an unmapped register reads back as 0 and would
  otherwise be mistaken for a real epoch of 0.
- `tools/odo_gen` stamps the epoch seed, validity window and regenerate
  command into `encrypt.v`, so a stale copy is visible by inspection instead
  of needing a regenerate-and-diff to date it.
- `tools/check-epoch.sh` verifies encrypt.v's stamp agrees with ODO_SEED and
  reports staleness against the current date.

### Still open
The tree's epoch is stale (seed 1786752000, rolled over 2026-08-25).
Regenerating changes the sbox contents and invalidates place-and-route, so it
is a deliberate step to take at a safe point -- check-epoch.sh prints the
commands.

---


## Performance Tuning — OPTIONAL

### Hashrate Target
- Single-core: ~0.5 MH/s (1x 420 RAMB18 hash engine)
- Dual-core (current bitstream): ~1.0 MH/s (2x parallel engines)
- Theoretical max (Kintex-7 BRAM): ~2.5 MH/s (if routability allows)

### Potential Optimizations
1. **Clock Frequency** — Increase miner clock from current ~70 MHz → 100+ MHz
   - Requires place-and-route validation (Vivado timing analysis)
   - Impact: +30-50% hashrate if timing passes

2. **Throughput Tuning** — Adjust `THROUGHPUT` parameter in `encrypt.v`
   - Current: THROUGHPUT=4 (embedded in bitstream)
   - Recompile with THROUGHPUT=6 or 8 for different BRAM/LUT tradeoff
   - No hashrate gain alone; combined with Fmax tuning

3. **Pipelining Depth** — Add register stages to reduce critical path
   - Impact: +20-30% Fmax at cost of +1-2 cycle latency
   - Effort: moderate (RTL + validation)

### Current Status
- Vivado bitstream is NOT timing-optimized
- Primary goal was to verify functionality, not max performance
- Tuning deferred to "production hardening" phase

---

## Branch/Variant Tracking

| Variant | Status | Notes |
|---------|--------|-------|
| **AM01 (stock, Zynq)** | ⚠️ Untested | Zynq AXI-Lite interface; separate repo branch |
| **QMTech Kintex-7 (this one)** | ✅ In Progress | GPIO wrapper; Vivado bitstream ready |
| **OpenXC7 (open-source PnR)** | 🔄 WIP | nextpnr-xilinx; yosys synthesis; replacing Vivado |
| **Cyclone V SoC (reference)** | ✅ Deployed | odo-miner-cyclonev; 485+ blocks mined |

---

## Checklist for "Production Ready"

- [ ] Daemon mines and gets accepted shares on testnet pool
- [ ] Automatic pool reconnect on network dropout
- [ ] Web dashboard accessible and updating
- [ ] Touch UI renders correctly (if display hardware present)
- [ ] Epoch update script tested (manual and automatic)
- [ ] Temperature/fan control working (if DS18B20 + PWM present)
- [ ] Bitstream survives 24+ hours uptime without crashing
- [ ] Graceful shutdown (systemctl stop odo-miner)
- [ ] Cold-boot recovery (power cycle → automatic re-mining)
- [ ] Logs are properly rotated (journalctl doesn't fill disk)

