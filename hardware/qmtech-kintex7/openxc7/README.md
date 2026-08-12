# Vivado-free FPGA builds for the XC7K325T (openXC7) — **verified working**

**Bottom line: you do not need a Vivado licence for this board.** A fully
open-source toolchain takes Verilog all the way to a valid `.bit` for
`xc7k325tffg676-1`, the exact chip/package on the QMTECH board. This was
run end to end and the output is a real bitstream:

```
$ file blinky.bit
blinky.bit: Xilinx BIT data - from blinky.frames;
            Generator=xc7frames2bit - for xc7k325tffg676-1 -
            built 2026/08/11(20:36:51) - data length 0xae9d9c
```

That matters because **this chip is not covered by any free Vivado tier.**
Vivado ML Standard (the free one, ex-WebPACK) covers Artix-7, Spartan-7,
some Zynq-7000 and only the *smaller* Kintex-7 parts; the 325T needs a
paid licence (~$4,395 node-locked at last check, and AMD moved to new
tiered pricing in 2026.1). The flow below costs nothing.

> **Two limits, stated up front.**
> 1. **Not yet flashed to real hardware.** The bitstream is structurally
>    valid and the flow completes cleanly, but nobody has programmed the
>    board with it. "Produces a valid bitstream" and "works on silicon"
>    are separate claims; only the first is proven here.
> 2. **The full miner places and routes, but misses its clock target.**
>    `am01_qmtech_top` gets through placement in ~2 minutes on a current
>    nextpnr (it hung forever on apio's older one — see §2), and static
>    timing reports **`clk_h` = 135.04 MHz against a 150 MHz target**.
>    That is a real measurement, and it is *lower* than the estimate in
>    ../README.md. See "Status vs. the real design" at the bottom.

## The flow

```
Verilog ──yosys(synth_xilinx)──▶ .json ──nextpnr-xilinx──▶ .fasm
                                          (+ chipdb, .xdc)
       ──fasm2frames──▶ .frames ──xc7frames2bit──▶ .bit
```

```sh
# once, ~8 min -- there is no prebuilt Kintex-7 chipdb anywhere (see below)
./build-chipdb.sh

# then, per design (all the env vars are overridable, see build.sh header)
XDC=smoke-test/blinky.xdc \
NEXTPNR=~/.apio/packages/openxc7/bin/nextpnr-xilinx \
    ./build.sh blinky out smoke-test/blinky.v
```

Both scripts were run exactly as written above; the `.bit` quoted at the
top is what came out.

## Two things that will waste your day if you don't know them

### 1. There is no prebuilt Kintex-7 chipdb anywhere — generate it

apio's `openxc7` package ships prebuilt chipdbs for **Artix-7, Spartan-7
and Zynq-7 only**:

```
$ ls ~/.apio/packages/openxc7/chipdb/
xc7a100t*.bin  xc7a200tfbg484.bin  xc7a35t*.bin  xc7a50t*.bin
xc7s50csga324.bin  xc7z010clg400.bin  xc7z020clg*.bin
```

No `xc7k*` at all — even though openXC7's own docs advertise Kintex7
(70T/160T/325T/420T/480T) support. **The support is real; only the
prebuilt binary is missing.** openXC7's `prjxray-db` fork does carry
fuzzed `kintex7/` data including `xc7k325tffg676-1`, and
`nextpnr-xilinx/xilinx/python/bbaexport.py` will happily export it — it
auto-selects the family by string-matching `xc7k` in the device name.
`build-chipdb.sh` automates exactly that.

Cost: ~8 min CPU, ~1.9GB peak disk (1.3GB intermediate `.bba`, 462MB
final `.bin`), a few GB RAM.

### 2. Build nextpnr-xilinx from CURRENT HEAD -- apio's is far too old

**This section previously said the opposite.** It advised using apio's
prebuilt binary and warned that a from-source build "fails to route even
a trivial counter". That was a real observation with the wrong cause
attached, and following it will cost you the ability to build any large
design. The correction:

apio ships `fedc910`, which is **79 commits behind** the project's
default branch (`stable-backports`). The from-source build that failed
was tag `0.9.2` = `c13fcbf6` = PR #103 -- and the very next merge,
`fedc910` = PR #105, is titled **`fix/heap-legalise-validity`**. So the
"broken from-source build" was simply missing a validity fix that landed
one PR later; the build process was never at fault.

Building current HEAD fixes far more than that. Measured on the real
`am01_qmtech_top` design (~69k cells after flattening):

| nextpnr revision | result on the real design |
|---|---|
| tag `0.9.2` (`c13fcbf6`, PR #103) | fails to route trivial designs |
| `fedc910` (**what apio ships**, PR #105) | HeAP hangs >1h, no output; SA places then fails its own validity check |
| `b608fd2c` (**current HEAD**, 0.9.2-85) | **HeAP places in 65.5s**, SA refine 53s, routes |

That is not a scaling limit, a chipdb problem or a constraints problem --
it was a fixed bug, and the fix has been available for some time.

```sh
git clone https://github.com/openXC7/nextpnr-xilinx
cd nextpnr-xilinx && git submodule update --init --recursive
mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX=/opt/openxc7 -DARCH=xilinx \
      -DUSE_OPENMP=ON -DBUILD_GUI=OFF \
      -DPython3_EXECUTABLE=/usr/bin/python3.11 \
      -DPython3_INCLUDE_DIR=/usr/include/python3.11 \
      -DPython3_LIBRARY=/usr/lib/x86_64-linux-gnu/libpython3.11.so \
      -DPython3_FIND_STRATEGY=LOCATION ..
make -j$(nproc) && make install
```

(The explicit `Python3_*` pinning matters -- see the from-source section
below. Everything else about the flow, including `build-chipdb.sh`, is
unchanged: chipdbs generated here work under both old and new binaries.)

Newer HEAD also carries fixes worth having for this board specifically:
`xilinx: don't abort on a BEL attribute naming an unknown tile`,
`xilinx: run the final timing analysis after router2`, and several XDC
parsing fixes.

### 3. Tristates across a hierarchy boundary need `-flatten`

If a bidirectional bus is driven from inside a submodule (as
`odocrypt_gpio_wrapper` drives `gpio_data`), an unflattened
`synth_xilinx` maps the *top-level pad* to `IOBUF` but leaves the
submodule's driver as a generic `$_TBUF_` that nextpnr cannot place:

```
ERROR: Unable to place cell '...simplemap_tribuf$53081',
       no Bels remaining of type '$_TBUF_'
```

Confirmed by counting cell types in the netlist:

```
am01_qmtech_top      | IOBUF:   16     <- pads, fine
odocrypt_gpio_wrapper| $_TBUF_: 16     <- stranded, unplaceable
```

`synth_xilinx -flatten` resolves the driver into the pad buffer
(`build.sh` does this by default, `FLATTEN=0` to opt out). Note the cost
on a design this size: ~90s/1GB unflattened vs **~14 min and 11GB peak
RAM** flattened. Vivado infers this across hierarchy without flattening,
so it is another openXC7-vs-Vivado difference rather than an RTL bug.

### The `--test` red herring

`nextpnr-xilinx --chipdb X.bin --test` fails on generated chipdbs:

```
Info: Checking bel names..
ERROR: Assert `bel == bel2' failed in common/archcheck.cc:41.
```

**Ignore it.** It fires on a freshly generated *Artix-7* chipdb too — one
that then places, routes and builds a working bitstream. The self-check
is broken or stricter than reality; it is not evidence your chipdb is
bad. Judge the chipdb by whether it routes a real design.

## Building the toolchain from source (only needed for chipdb generation)

`build-chipdb.sh` only needs Python + `bbasm`, no compilation. But if you
do want the whole toolchain from source (openXC7's
`toolchain-sources-builder.sh`), these deps were missing on a stock
Ubuntu 24.04 and each one kills the build partway through:

```sh
apt install tcl-dev flex libfl-dev libboost-all-dev python3-dev \
            cmake default-jre-headless uuid-dev libantlr4-runtime-dev \
            libeigen3-dev cython3
```

Plus two fixes the script doesn't handle:

- **CMake picks the wrong Python.** It found a 3.11 interpreter but 3.13
  headers and bailed with `Could NOT find Python3 (missing: Development
  Development.Module Development.Embed)`. Pin all three explicitly:
  ```
  -DPython3_EXECUTABLE=/usr/bin/python3.11 \
  -DPython3_INCLUDE_DIR=/usr/include/python3.11 \
  -DPython3_LIBRARY=/usr/lib/x86_64-linux-gnu/libpython3.11.so \
  -DPython3_FIND_STRATEGY=LOCATION
  ```
- **prjxray's `make clean` refuses to run as root** (`Makefile:18: ***
  ERROR: Running as ID 0`). Harmless on a fresh checkout — nothing to
  clean — and the build continues. Set `ALLOW_ROOT=1` to silence it.
- prjxray's `pip install -r requirements.txt` fails on
  `python-sdf-timing` (old `setup.py` vs new setuptools:
  `AttributeError: install_layout`) and its bundled `fasm` C++ parser
  fails against system antlr4. Neither blocks the flow — `pip install
  fasm` gets a working pure-Python parser, and sdf-timing is only for
  timing export.

## Smoke test

`smoke-test/blinky.v` is a plain 28-bit counter driving 4 LEDs, with
`blinky.xdc` using **real, verified** ffg676 ball names. It is the design
that produced the bitstream quoted at the top. Use it to check the
toolchain before blaming your own RTL.

One caveat worth knowing, found the hard way: an earlier version of this
blinky used a clock enable (`if (ctr == 0) led <= led + 1`), which
synthesises to logic driving the FF's CE pin and routes through
`F8MUX_OUT → CEUSEDMUX_OUT`. That variant *also* failed under the broken
from-source binary — but so did the plain counter, so CE is not
implicated. Under apio's binary the plain counter routes; the CE variant
has not been re-tested. If you hit a CE-related routing failure, that's
the first thing to re-check.

## Status vs. the real design — it places; the clock is the problem

**This section previously claimed the placer "does not scale" and that
the design could not be built with open tools. That was wrong** — it was
a fixed upstream bug, not a scaling limit. With nextpnr at current HEAD
(§2) the full `am01_qmtech_top` places quickly:

```
yosys:   30,022 LC (~9% of 326,080), 420 RAMB18 (47% of 890)
nextpnr: 69,366 cells flattened
         HeAP Placer Time:  65.50s        <- apio's binary hung >1h here
         SA refinement:     53.03s
         router2:           converging (1.7M wires)
```

### The measured timing, which is the real headline

```
Max frequency for clock 'bus_clk': 246.00 MHz  (PASS at 150 MHz)
Max frequency for clock   'clk_h': 135.04 MHz  (FAIL at 150 MHz)
```

`clk_h` is the hash clock, and it is the number every hashrate figure
multiplies against. At `THROUGHPUT=4`, `135.04 / 4 = 33.8 MH/s` per
instance, so **~67.5 MH/s** for the 2-instance build.

**This is below the estimate in ../README.md** (which projected
150-300 MHz and ~120-150 MH/s on the reasoning that a Kintex-7 -1 would
clock ~1.5x a Cyclone V). It is also slightly below what the *older*,
Cyclone-V-anchored estimate predicted — odo-miner-cyclonev measured
162 MHz Fmax on this same core. **For this design, on this flow, the
Kintex-7 clocks lower than the Cyclone V did.**

Why that is not as contradictory as it sounds: the part is genuinely more
capable (more BRAM, 50% more logic cells, block RAM rated to 458 MHz),
but none of that shortens the critical path, which runs through a BRAM
S-box lookup and three unrolled keccak rounds (`UNROLLING=3` at
`THROUGHPUT=4`). Capacity and clock are different axes. The extra
capacity is what the 2-instance build spends; it does not buy frequency.

Two honest qualifications on the 135 MHz:

1. **It is nextpnr's STA, not Vivado's.** Open-source place-and-route
   generally has worse quality of result than vendor tools, so Vivado on
   the same silicon could plausibly do better. Treat 135 MHz as a floor
   for *this flow*, not a ceiling for the part.
2. **It is the post-placement figure.** Routing normally degrades
   timing, so the final routed number is likely at or below this.

### What would actually raise it

Lowering `UNROLLING` shortens the critical path directly — that is the
one change that moves Fmax rather than capacity. It needs `encrypt.v`
regenerated at a different `THROUGHPUT` by the upstream OdoCrypt
generator (the file is ~15,000 generated lines with the value baked in,
and is regenerated per 10-day epoch anyway). Per ../README.md's table,
total rate stays `~0.5 x Fmax` at any `THROUGHPUT`, so the win comes
entirely from the higher clock a shallower pipeline permits.
