# Renaming away from "AM01"

The name is wrong and should go. **AM01 is AtomMiner's product** — this repo is
a fork of `atomminer/am01`, whose original five files documented an **XC7A200T
Artix-7** board. This project builds on a QMTECH **XC7K325T Kintex-7** with a
Raspberry Pi CM4. Different chip, different family, different board.

This file is the plan. It is written down because the rename is **not** a
find-and-replace: sixteen of the names are live on a running board, and getting
the order wrong leaves it booting with a dead miner.

---

## Scope

```
filenames containing am01        41
tracked files mentioning am01   292
total mentions                1571
```

Three tiers, in increasing order of danger.

### Tier 1 — free (no runtime coupling)

Comments, documentation, variable names, Verilog module names, test names. A
`sed` and a rebuild. The **case is already clean**: its files are
`qmtech_xc7k325t_case_*.scad` and contain no mention.

Notable filenames: `hdl/am01_qmtech_top*.v`, `cm4-firmware/am01_gpio_bus.[ch]`,
`cyd/host/am01-uartd.c`, `linux/am01-fpga-gpio.dts`, `BUILD_AM01.sh`.

Renaming a top-level Verilog module means updating `vivado/build*.tcl`'s
`set_property top`, and the openXC7 scripts' `TOP=`. Miss one and the build
fails loudly, which is the good kind of coupling.

### Tier 2 — needs a rebuild and a reflash

Anything the FPGA or the cross-compiled binaries carry. Rename, rebuild,
validate with `tools/validate-bitstream.sh`, deploy. No special ordering.

Six installed binaries: `am01_bus_test`, `am01_diag`, `am01_busbench`,
`am01_smoke`, `am01_probe`, `am01_reg`. `docs/TODO.md` cites
`am01_probe fan 255`, so update the docs in the same commit.

### Tier 3 — DANGEROUS: live on the board

Sixteen paths installed by the overlay, eight of which cross-reference each
other:

```
/etc/systemd/system/am01-fpga.service
/etc/systemd/system/am01-wifi.service
/etc/systemd/system/am01-wifi-provision.service
/etc/systemd/system/am01-ssh-provision.service
/etc/systemd/system/am01-miner-provision.service
/etc/systemd/system/am01-panel-helper.service
/etc/systemd/system/am01-panel-helper.path
/etc/systemd/system-preset/00-am01.preset
/etc/default/am01-fpga
/etc/modules-load.d/am01-usb-gadget.conf
/etc/udev/rules.d/81-am01-wifi-powersave.rules
/etc/udev/rules.d/99-am01-gpio.rules
/usr/bin/am01-fpga-reload
/usr/bin/am01-panel-helper
/usr/bin/am01-panel-ota
/usr/bin/am01-provision
```

**Renaming a unit file does not rename the enabled symlink.** `systemctl
enable` writes a symlink in `/etc/systemd/system/multi-user.target.wants/`
pointing at the OLD name. Ship a new overlay without disabling the old units
first and the board boots with dangling symlinks and no miner.

`am01-panel-helper` is worse than the rest: the `.path` unit watches a
directory and triggers the `.service`, so **both** must move together, and
`odo-webd` and the CYD panel both write request files that the helper consumes.
`hardware/qmtech-kintex7/linux/test-panel-helper.sh` has 51 checks over it —
run them.

---

## Order of operations

Do this with the board **in front of you**, not over SSH from another room.

1. **Take a working image or a full backup.** The recovery path if this goes
   wrong is reflashing the eMMC, so have something to reflash.
2. Rename tiers 1 and 2, rebuild everything, run `sim/run_all_sims.sh`,
   `cyd/sim make check`, `linux/test-panel-helper.sh`, and `sw make all`.
3. Rename tier 3 in the overlay, **including every cross-reference** — the
   eight files that name each other, `INSTALL.md`, and the preset.
4. On the board, **disable the old units before installing the new overlay**:
   ```sh
   systemctl disable am01-fpga am01-wifi am01-wifi-provision \
                     am01-ssh-provision am01-miner-provision \
                     am01-panel-helper.service am01-panel-helper.path
   ```
5. Install the new overlay, `systemctl daemon-reload`, enable the new units,
   reboot.
6. Verify: the miner mines, the panel updates, WiFi comes back after a reboot,
   and `am01-panel-helper`'s replacement still applies a pool change from the
   web UI.
7. Remove the old files only once the new ones are proven.

---

## When

**After the epoch rebuild ships and is validated.** The epoch rolls
2026-09-14 00:00 UTC and a stale bitstream mines rejects immediately, so that
deadline owns the calendar until it is met.

A repo migration tangled with a hard deadline on the machine that is earning is
how uncommitted work gets lost — and this project has already paid for that
lesson once, with an `encrypt.v` that sat uncommitted while two bitstreams were
built from it.

Sequence: epoch build validated → move to the new repo → **then** this rename,
in its own session.

---

## What to rename to

Not decided. The repo is going to `K7-Odo-Miner`, so `k7-` is the obvious
prefix: `k7-fpga.service`, `k7-panel-helper`, `k7_gpio_bus.c`. Whatever is
chosen, keep it consistent across all three tiers in one commit per tier —
a half-renamed tree is worse than either end state.

Note that `odo-miner`, `odo-webd` and `odo-ui` are **already** named for the
algorithm rather than the board, and should not change.
