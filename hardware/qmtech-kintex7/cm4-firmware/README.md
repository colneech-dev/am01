# CM4-side bus driver (bit-banged GPIO)

Userspace Linux driver for the parallel bus `../hdl/odocrypt_gpio_wrapper.v`
implements on the FPGA side. Talks to it via [libgpiod](https://libgpiod.readthedocs.io/)
using plain bit-banged GPIO -- the simple path, not the BCM2711 SMI
peripheral the QMTECH manual mentions as a faster option (see "SMI vs.
bit-bang" below).

**Status**: reference skeleton. Written to match the register map and
4-phase handshake in `../hdl/odocrypt_gpio_wrapper.v` exactly, but not
compiled against a real libgpiod or run against real hardware as part of
this repo — see the top-level `../README.md`'s "what's still needed" list.

## Build

On the CM4 (Raspberry Pi OS / Armbian / Debian-based):

```sh
sudo apt install libgpiod-dev gpiod
cd hardware/qmtech-kintex7/cm4-firmware
make
```

## Run

```sh
# Find the right gpiochip and confirm line offsets first:
gpioinfo

sudo ./am01_bus_test           # defaults to gpiochip0
# or: sudo ./am01_bus_test gpiochip4
```

Needs GPIO access — either run as root, or add udev rules / group
membership (`gpio` group on Raspberry Pi OS) so it doesn't need `sudo`.

`am01_bus_test` reads `STATUS`, submits an all-zero dummy work item, and
waits (30s) for a nonce IRQ — a timeout there is *expected* with dummy
all-zero work; it's just proving the bus round-trips end to end (register
read works, 27-word submit sequence completes, IRQ line is wired
correctly) before you plug in a real pool/stratum client.

## The gpiochip/offset assumption — verify before trusting this

`am01_gpio_bus.c`'s `DATA_OFFSETS`/`ADDR_OFFSETS`/`WR_N_OFFSET`/etc. assume
the gpiochip line offset for each pin equals the "GPIOn" number from the
QMTECH manual's CM4 pinout table (e.g. `GPIO5` → offset 5). That's true on
most mainline Raspberry Pi kernels, but isn't guaranteed — Broadcom's
pinctrl numbering has shifted across kernel versions before, and it may
differ again on non-genuine CM4 clones (see the AliExpress Orange Pi CM4
conversation — if you end up using that instead of a genuine Pi CM4,
double-check its GPIO numbering/chip separately). Run `gpioinfo` on your
actual boot image and cross-check against the table in `../README.md`
before trusting the offsets in this file.

## SMI vs. bit-bang

This driver bit-bangs every bit of every beat through individual
`gpiod_line_set_value`/`get_value` calls — simple, portable, and almost
certainly fast enough here (27 words per work item, one nonce read per
solve; the actual data volume this whole conversation has been about is
tiny). If profiling later shows the host link is somehow a bottleneck,
the QMTECH manual calls out the BCM2711's SMI (Secondary Memory Interface)
peripheral as a faster alternative — that's real hardware-timed parallel
bus support built into the SoC, but needs a device-tree overlay and
either a small kernel driver or the `/dev/smi` interface some Pi kernels
expose. Not implemented here; start with this bit-banged version and only
reach for SMI if you actually need the throughput.

## Wiring the result up to a real miner

`am01_bus_test.c` is a bring-up smoke test, not a miner. To do anything
useful:

1. Get real header/target words from a pool connection (stratum client)
   instead of the all-zero dummy in `am01_bus_test.c`.
2. Call `am01_bus_submit_work()` with them.
3. Call `am01_bus_wait_irq()` (or poll `am01_bus_read_status()`) and
   `am01_bus_read_nonce()` when a solution comes back.
4. Submit the share back to the pool.

None of the stratum/pool-protocol side is included here — this library
only covers the FPGA-facing half of that loop.
