# Installing the AM01 miner image on the CM4

End-to-end: build image -> flash eMMC -> first boot -> prove the FPGA bus ->
mine. Written for a CM4 **with eMMC** docked on the QMTECH XC7K325T board.

Nothing here has been run on real hardware yet. Steps that are unverified are
marked. Expect the FPGA bus bring-up (step 6) to be where the work is: the
driver has never talked to a real FPGA.

---

## 0. Before you start: is the epoch current?

OdoCrypt mutates every 10 days. A bitstream built for a past epoch mines
shares the pool rejects, and the board cannot tell you unless the bitstream
carries the SEED register.

```sh
tools/check-epoch.sh
```

- exit 0 — current, carry on
- exit 1 — **stale**; the script prints the regenerate commands
- exit 2 — encrypt.v and ODO_SEED disagree; fix before building anything

Regenerating changes the sbox contents and invalidates existing
place-and-route results, so do it at a point where that is acceptable.

---

## 1. Build the image

From WSL, not from `/mnt/c/...` — Buildroot rejects a PATH containing spaces,
and this machine's `Documents/GitHub` path has them.

```sh
cd ~/br-am01/buildroot
make BR2_EXTERNAL=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/buildroot \
     defconfig BR2_DEFCONFIG=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/linux/buildroot_cm4_defconfig
make
```

Output: `output/images/sdcard.img` (~765 MB), a full disk image with a FAT
boot partition and an ext4 root.

Two quirks of this machine, both already worked around but worth knowing if
the build fails on a fresh checkout:

- WSL's `install` is uutils, which breaks Buildroot. A wrapper at
  `~/bin/install` exec's `/usr/bin/gnuinstall`, with `~/bin` first on PATH.
- `rpi-firmware` and `linux-firmware` stamp-cache their install step. If you
  change `config.txt` or enable extra firmware, `make <pkg>-dirclean` first
  or the change will not reach the image.

---

## 2. Get the image onto Windows

```
\\wsl$\Ubuntu\home\colin\br-am01\buildroot\output\images\sdcard.img
```

Copy it somewhere local; writing directly over the WSL share is slower and
more failure-prone.

---

## 3. Install rpiboot (Windows)

From <https://github.com/raspberrypi/usbboot> — the Windows installer.

**Not** the `rpiboot` inside the image: that one is an aarch64 binary built
for the target and will not run on your PC.

---

## 4. Flash the eMMC

The CM4's eMMC is only visible to a host when the module is held in USB boot
mode.

1. Power off the board.
2. Pull **nRPIBOOT** low. It is broken out on **JP7** (schematic sheet 1,
   alongside GLOBAL_EN, RUN_PG, SCL0/SDA0). *Check the exact pin against the
   schematic — I could not read the pin numbering reliably from the PDF
   render, and shorting the wrong pin here is not harmless.*
3. Leave **JP6 open**. The manual (section 2.2.9) flags pins 86 and 88 as
   3.3V/1.8V *outputs*; jumpering them is a way to damage the module.
4. Connect the **mini-USB J14** to your PC.
5. Apply power.
6. Run `rpiboot`. The eMMC should enumerate as a USB mass-storage device.
7. Write `sdcard.img` to that whole disk — Raspberry Pi Imager ("Use custom")
   or balenaEtcher. Pick the *device*, not a partition.
8. Power off, remove the nRPIBOOT jumper, power on.

The image is ~765 MB and the root filesystem is a fixed 700 MB, so most of
the eMMC will be unallocated. That is fine; nothing here needs the space.

---

## 5. First boot — getting in

Two routes. Try serial first: it works with no network at all.

### Serial console over the mini-USB (J14)

The same cable you flashed with. The CM4 exposes a USB CDC-ACM gadget, so it
appears as a COM port on your PC. 115200 8N1, though for a USB gadget the
baud rate is nominal.

There is **no UART console on the GPIO header**, and this is not an
oversight: the manual's section 2.2.9 pin table routes GPIO0–27 to the FPGA,
so GPIO14/15 are data bus bits 14 and 15 rather than TXD/RXD. Every
alternate CM4 UART (uart2–uart5) lands inside the same range.

Note the mini-USB and the four USB-A ports **cannot both be live**: the
FSUSB42MUX switches between them from the cable's ID pin. With J14 connected
you get the gadget console and the USB-A ports go dark. Unplug it and the
hub comes back.

### SSH over Ethernet

`eth0` takes DHCP. There is no avahi, so `am01-miner.local` will not resolve
— find the address in your router's lease table, or run `ip addr` on the
serial console.

```
ssh root@<address>
```

Login is `root` / `changeme` on both routes. **Change it immediately**
(`passwd`). Root password login over SSH is enabled deliberately, because
root is the only account and the alternative is serial-only access — it is a
weak default for a LAN appliance. Better still, add an `authorized_keys` and
set `PermitRootLogin prohibit-password` back.

WiFi is configured for `vodofoneAAB7F3` and should associate on its own. The
credential file is gitignored, so a fresh clone builds an image without it
and `am01-wifi.service` skips rather than failing.

---

## 6. Prove the FPGA bus before mining anything

**Do this before starting the miner.** The bus driver has never run against a
real FPGA; the miner is a much worse place to discover the handshake is
wrong.

First confirm the line offsets are what the driver assumes — it takes
gpiochip line offset to equal the BCM GPIO number, which is usually but not
always true:

```sh
gpioinfo
```

Then, with a bitstream loaded:

```sh
am01_bus_test
```

It reads STATUS, submits an all-zero dummy work item and waits 30 s for a
nonce IRQ. **A timeout there is expected** with dummy work — what it proves
is that register reads round-trip, the 27-word submit sequence completes and
the IRQ line is wired. A failure *before* the timeout is a real problem.

---

## 7. Load the bitstream

Currently the FPGA is programmed externally over JTAG, and nothing in the
image interferes with that.

To let the board do it instead:

1. Put the bitstream on the boot partition as `/boot/am01.bit`.
2. Name your adapter in `/etc/default/am01-fpga`:
   ```sh
   openFPGALoader --scan-usb          # see what is attached
   FPGA_OPTS="-c ft2232"              # or -c digilent, etc.
   ```
   Add `-f` to write to flash rather than SRAM; without it the FPGA
   reconfigures on every boot.
3. `systemctl start am01-fpga` (it is enabled, and ordered before the miner).

With no `/boot/am01.bit` the unit is skipped, so external programming keeps
working unchanged.

**The CM4 cannot program the FPGA on its own.** There is no electrical path:
the manual's section 2.2.9 GPIO table wires all 28 CM4 GPIOs to FPGA fabric
pins (the parallel bus), while J1 and the SPI flash both land only on the
FPGA's *dedicated configuration* pins (`TMS_0`/`TCK_0`/`TDO_0`/`TDI_0` and
`FPGA_CCLK`/`FPGA_DQ0-3`/`FPGA_CSO_B` on U11A, schematic sheets 1-2). No
CM4 pin reaches either, so JTAG bit-banging from GPIO is not an option
regardless of software. A USB-JTAG adapter is required.

For unattended epoch renewal, leave the adapter plugged into one of the
board's USB-A ports. The alternative that needs no adapter at all is
STARTUPE2/ICAPE2 self-reconfiguration -- the fabric can reach the SPI
config pins after configuration, so the Pi could stream a new bitstream
over the existing GPIO bus and have the FPGA rewrite its own flash. That
needs real HDL work plus a MultiBoot golden image, since a failed write
would otherwise leave the board unconfigurable except by JTAG.

---

## 8. Configure the pool and start mining

```sh
vi /etc/default/odo-miner
```

```sh
DAEMON_OPTS="--host YOUR_POOL --port 3333 --worker YOUR_WALLET.am01"
```

The shipped value is a placeholder and will not connect. Then:

```sh
systemctl restart odo-miner
journalctl -u odo-miner -f
```

Watch for this line:

```
WARN job epoch N != bitstream epoch M — bitstream stale; shares invalid
```

That means exactly what it says, and step 0 is where you fix it. If it prints
`bitstream epoch 0`, the loaded bitstream predates the SEED register and the
staleness check cannot work at all.

Web dashboard, once the miner is up:

```sh
curl http://localhost:8080/status.json
```

`odo-ui` needs a framebuffer; with no display attached it is skipped rather
than failed.

---

## Order of operations, condensed

```
tools/check-epoch.sh          epoch current?
make                          build sdcard.img
rpiboot + write               flash eMMC
serial via J14                get in
gpioinfo                      line offsets sane?
am01_bus_test                 bus round-trips?
/etc/default/am01-fpga        bitstream, if Pi-driven
/etc/default/odo-miner        pool + wallet
journalctl -u odo-miner -f    mining?
```
