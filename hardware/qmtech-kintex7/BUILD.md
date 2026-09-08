# Building everything, from a clean checkout

Seven artefacts come out of this tree and they use five different toolchains,
two of which live on Windows and three inside WSL. This is the map.

`INSTALL.md` covers getting a built image onto a board. This covers producing
the things it installs.

Every flow below was run end to end on 2026-09-08 and the results are recorded
against it. Where something is broken or missing, it says so rather than
implying it works.

---

## 0. Where the tools actually are

This is the part that wastes the most time, because the toolchains are split
across two operating systems and two of them are not on `$PATH` at all.

| tool | lives | on PATH? |
|---|---|---|
| Vivado 2026.1 | `C:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat` (Windows) | **no** |
| PlatformIO | `%USERPROFILE%\.platformio\penv\Scripts\pio.exe` (Windows) | not from WSL |
| yosys, nextpnr-xilinx, fasm2frames, xc7frames2bit | `/opt/openxc7/bin` (WSL) | **no** |
| aarch64 cross-gcc | `~/br-am01/buildroot/output/host/bin` (WSL) | no |
| iverilog, gcc, python3 | WSL system | yes |

**Do not use `command -v` to look for the openXC7 tools.** It searches `$PATH`
only, and a stock `/opt/openxc7` install is not on it. `openxc7/build.sh`
resolves every tool through `toolchain.sh` — explicit env var, then
`toolchain.local` (gitignored, per-machine), then `$PATH`, then conventional
locations. Its own comments record this exact mistake being made and fixed.
To check what a build will actually use:

```sh
cd hardware/qmtech-kintex7/openxc7
. ./toolchain.sh
resolve_tool YOSYS yosys && echo "$YOSYS"
```

---

## 1. Verilog simulation suite

```sh
cd hardware/qmtech-kintex7/sim
bash run_all_sims.sh
```

**~15 minutes**, because the last two testbenches drive the real 259-stage
cipher under iverilog. Exit 0 and `ALL 6 VERILOG TESTBENCHES PASSED` is the
pass condition; the script greps each testbench's output and exits 1 on a
failure, because `$finish` exits 0 whatever a testbench concluded.

`tb_encrypt_oracle`'s vector is **epoch-specific** — see §6. A vector from the
wrong epoch fails for a reason that has nothing to do with correctness.

Each run compiles into its own `mktemp -d`, so concurrent runs no longer
clobber each other's executables.

---

## 2. CM4 host software

Nine binaries: `odo-miner`, `odo-webd`, `odo-ui`, `am01_bus_test`, `am01_diag`,
`am01_busbench`, `am01_smoke`, `am01_probe`, `am01_reg`.

```sh
cd hardware/qmtech-kintex7/sw
BR=~/br-am01/buildroot/output/host
make OBJ_DIR=obj-cross \
     CC=$BR/bin/aarch64-buildroot-linux-gnu-gcc \
     PKG_CONFIG=$BR/bin/pkg-config all
```

**`OBJ_DIR=obj-cross` is not optional.** `obj/` is shared with native builds
and a stale object of the wrong architecture is silently reused.

Deploy one binary:

```sh
scp odo-miner root@<board>:/tmp/odo-miner.new
ssh root@<board> "install -m 0755 /tmp/odo-miner.new /usr/bin/odo-miner \
                  && systemctl restart odo-miner"
```

Keep a backup on the board; several `odo-miner.bak-*` already exist there.

The build needs `odo-miner-cyclonev` checked out beside this repo — three `-I`
paths for the crypto oracle and header builder. Override with `ODO_REPO=`.

---

## 3. Host-side unit tests

```sh
cd hardware/qmtech-kintex7/cyd/sim && make check     # 9 tests, seconds
cd hardware/qmtech-kintex7/linux && bash test-panel-helper.sh   # 51 checks
```

`make check` also runs `check_pow_copy.py`, which fails the build if
`test_pow_math.c`'s transcribed `target_met`/`hash_to_difficulty` have drifted
from `miner_pipe_am01.c`. Those two decide whether a share is valid and what it
is worth, and the test does not link the real ones — they are `static`.

---

## 4. ESP32 front panel (CYD)

PlatformIO is a **Windows** install; run it from PowerShell, not WSL.

```powershell
cd hardware\qmtech-kintex7\cyd\firmware
& "$env:USERPROFILE\.platformio\penv\Scripts\pio.exe" run -e cyd
```

**~1m40s.** The environment is `cyd`, not `esp32dev` — an older note said
otherwise and was wrong. Last measured: RAM 8.0%, flash 40.5% of 1310720.

Versions are pinned in `platformio.ini`, all four of them, deliberately. Do not
float them.

Flashing needs BOOT held; see `cyd/README.md`, and note the display is
inverted and the panel is on the FPGA UART (JP5 15–18), not USB.

---

## 5. FPGA bitstream — Vivado

```powershell
cd hardware\qmtech-kintex7\vivado
& "C:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat" -mode batch `
    -source build_full.tcl -notrace -log build.log -journal build.jou
```

**~1h40m.**

**Use `build_full.tcl`, not `build.tcl`.** `build.tcl` only *creates the
project* and exits — it prints the next steps and stops. Launching it and
waiting for a bitstream costs an hour before you notice.

The result is archived into `vivado/artifacts/` with its clock and a timestamp
in the name, alongside its timing and utilisation reports.

**A positive WNS does not mean the bitstream is fit to mine.** Measured
2026-09-06/07, all at 225 MHz: WNS +0.273 ns → 96% of finds valid; +0.347 ns →
37% valid; and a 237.5 MHz build at +0.335 ns produced almost nothing valid.
The build with the most slack was the second worst. Validate on hardware:

```sh
# on the board
/usr/bin/am01-validate-bitstream /boot/candidate.bit 10
```

`tools/validate-bitstream.sh` flashes, runs, and judges on the fraction of
finds that survive the host's revalidation, plus a hard requirement that the
off-by-one recovery counter stays at zero. Exit 0 is a pass.

### mux4 (4 instances, shared BRAM) — experiment

```sh
cd hardware/qmtech-kintex7/tools
python mux2_transform.py ../../../hdl/odocrypt/encrypt.v ../hdl/mux4/encrypt_mux2.v
cd ../vivado
vivado -mode batch -source build_mux4.tcl -notrace
```

**Regenerate `encrypt_mux2.v` first, every time.** It is deliberately not in
git, and `build_mux4.tcl` refuses to build if it is missing or older than
`encrypt.v` — because a muxed S-box whose latency does not match its source
synthesises cleanly, fits, and computes garbage. That cost a full build once.

The number to read from this run is the **`clk_2x` WNS**, not the bitstream.
Per `hdl/odocrypt/IMPLEMENTATION-REVIEW.md`, muxed hashrate is exactly
`clk_2x / 2`, so the mux wins if and only if `clk_2x` beats 200 MHz.

---

## 6. Epoch regeneration — every 10 days

OdoCrypt mutates every 864000 seconds. A bitstream mines valid shares only
while the chain's job epoch equals the seed it was built from. **The next roll
is 2026-09-14.**

```sh
# 1. the cipher
cd tools/odo_gen && make
./odo_gen <seed> 4 encrypt_4 --bram-out-reg > ../../hdl/odocrypt/encrypt.v

# 2. ODO_SEED in hardware/qmtech-kintex7/hdl/odocrypt_gpio_wrapper.v must match
tools/check-epoch.sh

# 3. the simulation oracle vector
gcc -O2 -I<cyclonev>/hps -o gen_encrypt_vector \
    tools/gen_encrypt_vector.c <cyclonev>/hps/odocrypt_state.c
./gen_encrypt_vector <seed>       # paste over the localparams in
                                  # sim/tb_encrypt_oracle.v

# 4. if building mux4, regenerate encrypt_mux2.v (see §5)
# 5. rebuild the bitstream (§5) and validate it on hardware
```

**`--bram-out-reg` is not optional.** It registers each S-box's BRAM output,
taking a round from 2 cycles to 3, and it is what lets the design close timing.
Omitting it produces a different core: the round-key tap moves. `encrypt.v`'s
own header says so.

Step 3 is easy to skip and then `run_all_sims.sh` fails for a reason unrelated
to correctness. That happened, and the generator did not exist to fix it.

---

## 7. openXC7 (open-source bitstream flow)

```sh
cd hardware/qmtech-kintex7/openxc7
FREQ=133.33 ./build.sh
```

**Currently NOT ready.** `/opt/openxc7` ships **yosys 0.62 and nextpnr-xilinx
0.9.2**; this flow needs **yosys v0.68 and nextpnr-xilinx 0.9.3** built from
source with the patches in `patches/` and `patches-yosys/`. 0.9.2 cannot route
this design. Build them with `build-nextpnr-bramtiming.sh` and `build-chipdb.sh`
before using this flow.

Switching yosys 0.62 → 0.68 **invalidates comparability** with every
measurement taken before 2026-08-22: v0.68 produces a different netlist on this
design. Re-establish a baseline rather than carrying old figures forward.

openXC7 cannot time paths adjacent to a block RAM at all, and its XDC parser
understands only `set_property`, `create_clock` and `set_multicycle_path` —
everything else is discarded at INFO level. Do not read an openXC7 inter-clock
number as meaningful.

---

## 8. Buildroot CM4 image

**Blocked.** See the notes in `linux/`. Two known problems: spaces in the
Windows-side `PATH` reaching the build, and uutils' `install` behaving
differently from GNU coreutils'. The image builds under WSL at `~/br-am01`.

---

## Quick reference

| # | artefact | where | time | pass condition |
|---|---|---|---|---|
| 1 | Verilog sims | WSL | 15 min | `ALL 6 ... PASSED`, exit 0 |
| 2 | CM4 binaries | WSL | 1 min | 9 × `✓ Built` |
| 3 | host tests | WSL | seconds | 9 PASS + 51 checks |
| 4 | ESP32 firmware | Windows | 1m40s | `SUCCESS` |
| 5 | bitstream | Windows | 1h40m | archived .bit, then validate on hardware |
| 6 | epoch refresh | both | — | `check-epoch.sh`, then 1 and 5 |
| 7 | openXC7 | WSL | hours | not currently buildable |
| 8 | Buildroot image | WSL | hours | blocked |
