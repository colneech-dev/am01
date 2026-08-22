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

## Documents in this directory

Status at a glance, so you do not have to open each file to find out whether it
still applies.

| document | status |
|---|---|
| `README.md` | **current** — start here |
| `SESSIONS.md` | **current** — session record, newest first |
| `TESTS-TO-RUN.md` | **current**, with outcomes; most entries now refuted |
| `QUARANTINED-BITSTREAMS.md` | **current** — do not program these |
| `patches/README.md` | **current** — nextpnr patches, with what each is measured to do |
| `patches-yosys/README.md` | **current** — yosys patches |
| `upstream-issue-1-placer-flags.md` | valid, **not filed** |
| `upstream-issue-2-router2-relaxation.md` | valid, **not filed** |
| `upstream-issue-3-yosys-hdlname-loss.md` | **FILED** — YosysHQ/yosys#6144, PR #6145 |
| `upstream-issue-4-nextpnr-region-legalisation.md` | **FILED** — YosysHQ/nextpnr#1784 |
| `nextpnr-xilinx-control-set-bug.md` | **already fixed upstream** — reference only |
| `nextpnr-xilinx-router2-threadsafety-bug.md` | **already fixed upstream** — reference only |
| `router2_mt_partition.proposed.cc` | proposal, **not applied** |

### Check upstream before writing anything up

Four separate items in this directory were each written up as upstream
candidates and each turned out to be **already fixed upstream**:

| written up as a bug | actually |
|---|---|
| nextpnr control-set contention | fixed upstream (`bf78fccf`) |
| router2 backward-BFS thread safety | fixed upstream (`c42f87b3`, 2020-12-01) |
| `synth_xilinx` `-run` drops `ff_map` | fixed upstream after v0.68 |
| nextpnr cannot route `SRLC32E` | fixed; current netlists route with SRLs present |

The cause is the same every time: **a stale tree reproduces its own bugs
perfectly.** Local testing cannot detect that a bug is already fixed elsewhere,
because the local tool still has it. The check that finds these is comparing
against upstream HEAD — and against the meta-repo that pins versions
(`toolchain-installer`), not just the tool repos, since that is what revealed
this project was running yosys 0.62 and nextpnr 0.9.2 when openXC7 already
pinned v0.68 and 0.9.3.

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

The one attempt so far at a full route on the real (2-instance, 840-BRAM)
design placed cleanly (HeAP 300.41s, SA 202.19s -- slower than the table
above, which predates NUM_MINERS=2) and got 4 iterations into router2
before dying with the rest of a Windows reboot that killed the WSL2 VM.
**That was not router2 hanging** -- see below.

### router2 bounded termination -- it will not actually run forever

Checked directly in the installed binary's source (`common/router2.cc`,
currently-built commit `b608fd2c`, all genuinely upstream -- verified via
`git log --format='%an <%ae>'` on the file, not a local patch): router2's
negotiated-congestion loop has a real, env-overridable exit condition,
not an infinite `while(true)`:

```
int max_stall = 50;   // NEXTPNR_ROUTER2_MAX_STALL -- give up if overused-wire
                       // count doesn't improve for this many iterations
int max_iter  = 600;  // NEXTPNR_ROUTER2_MAX_ITER  -- hard iteration cap
```

Past either limit it `log_error`s out (aborting the build) **unless**
`NEXTPNR_SKIP_FAILED_ARCS=1` is set, in which case it accepts the
partial/overused route and lets `[3/4]`/`[4/4]` run anyway, producing a
`.bit` for inspection -- explicitly not one to program a board with,
since overused wires mean two nets are sharing a resource that can only
carry one signal.

Practical read: the "2+ day" prior run was never observed to actually
hit either cap or the loud failure message -- it was 4 iterations in
when the host rebooted, with no way from the log alone to say whether it
was close to converging, close to giving up, or neither. **The honest
status is "unknown, not yet re-attempted with a bounded run,"** not
"router2 doesn't work on this design." router2 is also internally
multithreaded (`std::thread`, not OpenMP) -- WSL2's `processors=` setting
in `.wslconfig` bounds how much of that it can use.

Recommended for the next attempt: run with `NEXTPNR_SKIP_FAILED_ARCS=1`
set so the flow completes end-to-end (through a possibly-overused `.bit`)
within the 600-iteration cap regardless of outcome, rather than an
unbounded wait -- then read the final `overused=` count in
`build.sh`'s new per-phase timestamps (see its header) to judge whether
a from-scratch full convergence run (unset the env var, let it run to
either 0 overuse or the loud failure) is worth the wall-clock time.

### `NEXTPNR_ARC_MAX_VISIT` -- the actual fix for the "2+ day" hang

Re-attempted per the above. Confirmed the "recommended" advice wrong in
one way: without `NEXTPNR_ARC_MAX_VISIT` set, router2 doesn't converge
*or* fail within any practical time -- it ran **5+ hours** on this
design's first outer iteration alone, never printing so much as an
`iter=1` summary line. Root cause, found directly in
`common/router2.cc`'s own comment: a failing arc's search is unbounded
by default and "drains the whole device graph before failing" --
`NEXTPNR_ARC_MAX_VISIT=20000` caps that, and the exact same design then
finished router2 in **35-40 minutes**, repeatably. Set this for any
attempt on a design with real congestion; it costs nothing on designs
that route cleanly.

### Why every reset in `../hdl/odocrypt_gpio_wrapper.v` is synchronous

With `NEXTPNR_ARC_MAX_VISIT` set, router2 reliably reaches the end --
and reliably then hits a real, different bug: nextpnr's own late-stage
legality check throws

```
ERROR: FASM: FF '...' at bel SLICE_XxYy/xFF disagrees with its
half-slice on 'is_sync'/'is_srused' -- control-set contention
in the placement
```

Xilinx 7-series half-slices share one physical SR (set/reset) network
per pair of flip-flops, and every flop sharing it must agree on: (a)
sync vs. async (`FDRE`/`FDSE` vs. `FDCE`/`FDPE`), and, less obviously,
(b) reset-vs-set polarity (`FDRE` vs. `FDSE`) even though both are
sync. nextpnr-xilinx's placer does not enforce either constraint during
placement -- it only notices at FASM-export time, and by default just
aborts (it does *not* silently ship a bad bitstream, despite how that
might read from the log). Vivado handles a mixed-primitive design fine;
this is purely an open-source-placer gap.

Traced with `select t:FDCE t:FDPE; dump` (or `t:FDSE`) after a normal
synth run -- yosys preserves `src` file:line attributes through
synthesis, so every offending cell's RTL origin was directly
identifiable, not guessed at. Both root causes turned out to be
`odocrypt_gpio_wrapper.v`-local, not in the shared `hdl/odocrypt/` hash
core:

1. **Async reset.** Three `always @(posedge bus_clk or negedge
   bus_rst_n)` blocks (all 84 `FDCE`/`FDPE` cells traced to exactly
   these three). `bus_rst_n` is already deasserted synchronously
   upstream (`am01_qmtech_top.v`'s `rst_stretch` counter), so nothing
   here needed true async behaviour -- dropping ` or negedge bus_rst_n`
   from the sensitivity list is a no-op functionally and removes the
   async cells entirely. (Tried first: forcing this via yosys's
   `dfflegalize -cell $_SDFFE_?P?P_ ...` instead of editing RTL --
   confirmed **not possible**, `dfflegalize`'s own supported-transforms
   list has no case for "convert async set/reset to sync".)
2. **Reset-to-1 polarity.** With (1) fixed, a *second*, different
   contention appeared: `FDRE` vs. `FDSE`. Traced to `wr_n_sync`/
   `rd_n_sync`, whose reset value is `3'b111` (correct -- these are
   active-low signals, so all-one is the safe idle state) -- but a
   reset-to-1 register synthesizes to `FDSE`, not `FDRE`, and that
   turns out to be just as half-slice-incompatible as async-vs-sync.
   Fix: store them inverted (active-high, `wr_sync`/`rd_sync`, idle =
   all-zero -> `FDRE`), un-inverting only at the two points that read
   them (`wr_active`/`rd_active`, and the two "CM4 released WR_N/RD_N"
   checks). Functionally identical, different bit polarity only.

After both fixes, `odocrypt_gpio_wrapper.v`'s own registers are 100%
`FDRE` -- but this did **not** turn out to be the whole story. Tracing
the *remaining* `FDSE` cells (same `select t:FDSE; dump` technique,
`src` attributes) after these two fixes found more, elsewhere:
`am01_qmtech_top.v`'s `rst_stretch` counter (same reset-to-1 pattern,
easy fix, still board-local) -- but also `hdl/odocrypt/keccak800.v` and
`hdl/odocrypt/encrypt.v`, the shared/generated hash-core RTL, with no
identifiable single-line cause (no explicit reset-to-1 pattern visible
in the RTL; these look like ABC-optimization-driven cell choices, not
something written explicitly). Full root-cause writeup and the
`dfflegalize`-level fix that closed it out **without** touching either
shared file: see `nextpnr-xilinx-control-set-bug.md` in this directory.
See also that file for a full six-attribute list (`negedge_ff`,
`is_latch`, `is_sync`, `is_clkinv`, `is_srused`, `is_ceused`) -- `is_sync`
and reset-value/`is_srused` are only two of the axes nextpnr-xilinx's
placer doesn't enforce; `is_ceused` (clock-enable used or not) is a
real third one, fixed the same way (`dfflegalize -mince`).

### Reducing routing congestion: placer/router density knobs

Once control-set contention was closed, P&R started completing
placement+routing cleanly (`0 errors`) but with a large `SKIP_FAILED_ARCS`
count buried in the warnings -- **do not trust an "0 errors" run without
also checking the warning content.** `NEXTPNR_SKIP_FAILED_ARCS=1` turns
what would be fatal unroutable-arc errors into warnings so the run can
finish; a bitstream built that way can have thousands of genuinely
unrouted signals despite reporting zero errors. Check with:
```sh
grep -c 'SKIP_FAILED_ARCS' build.log     # how many arcs never routed
grep 'iter=' out/*.pnr.log                # overused-wire trend per iteration
```
If `overused` converges to near-zero across iterations (it does for the
default, unconstrained flow -- the baseline reaches 0 by iteration 22; it
does **not** hold once cells are confined to regions, see "The placer has
no congestion model" below) but `SKIP_FAILED_ARCS` stays large, that's two
*different* router2 failure modes: congestion (resolved) vs. individual
arcs exhausting their `NEXTPNR_ARC_MAX_VISIT` search budget before finding
*any* path (not resolved). Raising `NEXTPNR_ARC_MAX_VISIT` (e.g.
20000 -> 200000) directly addresses the second one, at the cost of a
much slower run -- worth it for a design where congestion is real
(`overused` starts high) but transient.

The failures cluster hard around `RAMB18` (BRAM S-box) output/address
pins specifically, not randomly across the design -- consistent with
local placement density near the BRAM columns being the root cause, on
a chip that's otherwise only ~9% utilised overall. Two further,
untested-as-of-writing levers for relieving that local congestion at
the source (spread cells out more, so router2 needs less search depth
in the first place, rather than just giving it a bigger budget):

- **`placerHeap/beta`** (`common/placer_heap.cc`, default `0.9`): the
  HeAP placer's spreading trigger -- a region is treated as overfull
  (and cells get pushed out to less-dense neighbouring bins) once
  `cells > beta * bels`. Lowering it triggers spreading earlier/more
  aggressively.
- Also present in the same file, same access method: `placerHeap/alpha`
  (0.1), `placerHeap/criticalityExponent` (2), `placerHeap/timingWeight`
  (10). SA refinement (`placer1.cc`) has its own set:
  `placer1/constraintWeight` (10, CLI: `--cstrweight`),
  `placer1/netShareWeight` (0), `placer1/startTemp` (1, CLI:
  `--starttemp`). router2 itself has several more beyond
  `NEXTPNR_ARC_MAX_VISIT`/`NEXTPNR_ROUTER2_MAX_ITER`/`MAX_STALL`:
  `router2/bbMargin/x` and `/y` (3, per-net routing bounding-box
  slack), `router2/ipinCostAdder` (0.0), `router2/biasCostFactor`
  (0.25), `router2/initCurrCongWeight` (0.5), `router2/histCongWeight`
  (1.0), `router2/currCongWeightMult` (2.0), `router2/estimateWeight`
  (1.75).

**Important correction, checked directly rather than assumed:** searching
for these turns up `--placer-heap-beta`, `--placer-heap-critexp`, and a
`--router2-heatmap` congestion-visualisation flag -- but those are
**mainline YosysHQ/nextpnr** (the generic/ECP5/iCE40 architectures),
not this fork. Checked every `add_options()` call in
`common/command.cc` and `xilinx/main.cc` in the actual checkout this
binary was built from: none of those flags exist here. In this fork,
`placerHeap/*`/`placer1/*` (beyond the few with dedicated CLI flags
above) are reachable only via `ctx.settings['placerHeap/beta'] = 0.7`
in a `--pre-place <script.py>` hook (not yet tried/verified end-to-end).
router2's own heatmap-writing code (`write_heatmap()` in `router2.cc`)
exists but its only call site is compiled out (`#if 0`) -- using it
means patching the source and rebuilding, not a flag to flip.

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

Three qualifications on the 135 MHz. The third is the serious one and it
points the opposite way from the first.

1. **It is nextpnr's STA, not Vivado's.** Open-source place-and-route
   generally has worse quality of result than vendor tools, so Vivado on
   the same silicon could plausibly do better.
2. **It is the post-placement figure.** Routing normally degrades
   timing, so the final routed number is likely at or below this.
3. **nextpnr does not appear to time paths that start at a block RAM
   output on this chipdb** — so 135 MHz is a *fabric-only* figure, and
   the true Fmax of a design with 420 BRAMs per instance is likely
   **lower**, not higher. See below.

### nextpnr's STA does not see block RAM paths

Measured with three variants of the same S-box timing harness (20-40
S-boxes, LFSR-driven addresses, XOR-folded outputs, identical fold depth
in all three):

| harness | timed path | reported Fmax |
|---|---|---|
| stock S-boxes | BRAM out -> XOR fold -> FF | **840.34 MHz** |
| stock + fabric register | BRAM out -> **FF** -> XOR fold -> FF | **197.43 MHz** |
| shared-BRAM S-boxes | BRAM out -> FF -> XOR fold -> FF | **172.12 MHz** |

Inserting a register can only ever make each individual path *shorter*.
Reported Fmax fell from 840 to 197 MHz. A working timing model cannot
behave that way. The only consistent reading is that in the first row the
BRAM-to-fabric path was never considered at all, so the reported figure
came from some other, much shorter path.

Fabric timing itself is fine: 197 MHz for a ~6-LUT-level XOR tree is
about right. It is specifically the block-RAM arcs that are missing.

**What this means for every frequency number from this flow:** any
critical path running out of a BRAM is invisible. For a design that is
420 block RAMs per hash instance and whose critical path was assumed to
run "through a BRAM S-box lookup", that assumption cannot be what the
tool measured — such a path is exactly the kind it does not time. So
`clk_h = 135.04 MHz` should be read as *the worst fabric-to-fabric path*,
an upper bound on the real Fmax rather than a floor, and **~67.5 MH/s is
optimistic, not conservative**.

Qualification 1 above still stands on its own (Vivado may route better),
but it no longer makes 135 MHz safe to treat as a floor.

#### Root cause: prjxray-db ships no Kintex-7 timing data

It is not that nextpnr cannot time block RAM. It is that for this family
there is nothing to time it *with*:

| family | timing files in `prjxray-db/<family>/timings/` |
|---|---|
| artix7 | 50 |
| zynq7 | 45 |
| spartan7 | 44 |
| **kintex7** | **0** |
| virtex7 | 0 |

`xilinx_device.py` only attaches cell timing if
`<prjxray_root>/timings/<TILETYPE>.sdf` exists; with the directory
absent, `cell_timing` stays `None` and the chipdb is built with **no
cell delays at all** — no LUT delay, no flip-flop setup, no BRAM
clock-to-out. On top of that, every intra-site arc gets a hardcoded
placeholder in `nextpnr_structs.py`:

```python
# FIXME get from SDF
timing_class = self.timing.get_pip_class(
    is_buffered=True, min_delay=10, max_delay=10, r=0, c=0)
```

A flat 10 ps for any arc through a LUT or a BRAM. Only routing delays are
real, which is exactly why reported Fmax tracks logic *depth* (more hops)
while being blind to what the cells themselves cost. **So `clk_h` =
135.04 MHz is routing delay plus placeholder constants, not a timing
measurement of this part.**

#### Grafting Artix-7 timing onto Kintex-7: tried, does not fix it

Artix-7 and Kintex-7 are both 28 nm 7-series and share 29 tile types by
name, including `BRAM_L/R`, `CLBLL_L/R`, `CLBLM_L/R` and `DSP_L/R`. The
Artix-7 SDF has precisely the missing arcs, e.g.
`(IOPATH REGCLKBU DOBDOU (0.204::0.327)(0.468::0.882))`. Copying those 29
files into `kintex7/timings/` and rebuilding does load: the chipdb grows
by ~96 KB and the numbers move.

But it does **not** fix the defect:

| probe | no timing data | artix7 timing grafted |
|---|---|---|
| stock (BRAM -> fold) | 840.34 MHz | 754.72 MHz |
| stock + fabric register | 197.43 MHz | 191.86 MHz |
| shared-BRAM S-boxes | 172.12 MHz | 172.29 MHz |

Inserting a register still makes the reported frequency rise ~4x. Adding
cell delays improved their accuracy but did not make a block RAM output
into a timed start point, so BRAM-originating paths remain invisible.
Worth knowing this was tried; not worth carrying the graft.

#### So what would actually answer the question

- **Vivado STA.** The only sign-off-quality option, and this part needs a
  paid licence (see above).
- **Generating real Kintex-7 timing data** with prjxray's timing fuzzers
  requires Vivado to extract it — circular.
- **OpenSTA** needs Liberty models for 7-series primitives, which do not
  exist publicly and would also have to be derived from Vivado — equally
  circular.
- **A cut-down design on a free-tier Kintex-7 part.** This is the one
  free route that works. Whether the S-box address mux closes at
  266.67 MHz is a *local* path question — it does not depend on the
  325T's utilisation. Building a handful of shared S-boxes (see
  `../sim/` and the probe approach) for one of the smaller Kintex-7
  devices Vivado's free tier does cover would give a genuine 7-series STA
  answer for that path at no cost.

This also means the shared-BRAM S-box work in ../hdl/sbox_large_mux2.v
**cannot be timing-validated with this flow**: whether its address mux
closes at 266.67 MHz is precisely a question about a path adjacent to a
block RAM. The 172 MHz in the table above is the XOR fold in the test
harness, not the S-box. Replicating the interleave `phase` register to
cut its fanout from 421 to 21 changed the reported figure by nothing at
all (172.12 MHz before and after) — which is itself a good demonstration
that the number was never measuring the S-box.

### What would actually raise it

Lowering `UNROLLING` shortens the critical path directly — that is the
one change that moves Fmax rather than capacity. It needs `encrypt.v`
regenerated at a different `THROUGHPUT` by the upstream OdoCrypt
generator (the file is ~15,000 generated lines with the value baked in,
and is regenerated per 10-day epoch anyway). Per ../README.md's table,
total rate stays `~0.5 x Fmax` at any `THROUGHPUT`, so the win comes
entirely from the higher clock a shallower pipeline permits.

## The ceiling, measured: the design meets its target

Vivado placing and routing **our yosys netlist** (not its own synthesis):

```
clk_h   period 7.500 ns   WNS +1.203  ->  6.297 ns = 158.81 MHz   PASS @ 133.33
Number of Unrouted Nets = 0     Number of Node Overlaps = 0
```

Two things follow, and they close questions that were open for a long time.

**Yosys synthesis is not the bottleneck.** Our netlist reaches 158.81 MHz where
Vivado's own synthesis reaches 162 — ~2% apart, and that comparison favours
Vivado, whose run was NUM_MINERS=2. The rotation network is a genuine 7-input XOR
per bit, so two LUT levels is the arithmetic floor, not fat to be removed.

**The design meets 133.33 MHz on this part with this RTL.** So the RTL rework in
"What would actually raise it" is not required to hit spec — it is a
place-and-route gap, not a design one. openXC7 reaching ~102 MHz against 158.81
on identical input is a **1.55x tool gap**.

## The placer has no congestion model

This is the best single explanation for why placement tuning kept refuting.

`common/placer_heap.cc` minimises wirelength subject to **BEL capacity**. Every
occurrence of "congestion" in that file is a comment; `common/router2.cc` has 22
real congestion terms, the placer none. The spreader fires only on strict tile
overflow:

```cpp
if (occ_at(x, y, t) > bels_at(x, y, t)) { overutilised = true; break; }
```

On this design BEL utilisation is **9%** (40710/407600 LUTs), so tiles
essentially never overflow, the spreader is close to inert, and routing is
congested anyway.

The practical consequence: **placement metrics do not predict routability here.**
Wirelength and the post-placement timing estimate measure what the placer
optimises, which is not what limits this design. Confining each pipeline stage's
logic to a band around its own BRAMs improved both metrics (post-place 121.88 MHz
vs 97.47) and made the design unroutable — three runs, none converging, against a
baseline that reached zero overuse in 22 iterations:

```
iter | unconstrained | regions
  12 |          39   |    695
  17 |           4   |    638
  22 |           0   |    548   (still falling ~15/iter, oscillating)
```

`floorplan_stripe.py`'s own header records the same effect from an earlier
experiment: the N=1 block floorplan had the best wirelength of anything tried and
routing collapsed, because ~200 BRAM outputs leaving one 10-tile region saturate
local egress. Concentrating logic re-creates that at the LUT level.

**So: do not trust a placement improvement that has only been measured
post-placement.** Route it.

`NEXTPNR_WIRE_DEMAND=<cap>` (patch 0006, off by default) adds a RUDY routing-demand
estimate as a second spreader trigger, so the placer can react to congestion at
all. It is unmeasured — it addresses only the spreading trigger, not the analytic
solve.

## Hierarchy-aware floorplanning without external scripts

`GROUPS=1` groups cells by RTL scope and confines each group to a region, with no
Python anywhere in the flow:

```sh
GROUPS=1 FREQ=133.33 ./build.sh ...
```

```
yosys    synth_xilinx ... ; hdlname_recover ; write_json
nextpnr  --floorplan-hierarchy
```

It needs the local patched toolchain (see `patches/` and `patches-yosys/`).
Synthesis destroys cell provenance — after `synth_xilinx -flatten` only **2 of
70774** cells carry `hdlname`, because abc and the FF mapping create cells
without it — so yosys runs `hdlname_recover` to rebuild each cell's scope from
net names, which do survive flattening. nextpnr then groups by that, chooses the
grouping depth itself, and derives each region from the chipdb.

Filed upstream: YosysHQ/yosys#6144 (issue), YosysHQ/yosys#6145 (PR),
YosysHQ/nextpnr#1784 (issue).

**This does not currently improve timing on this design** — see the congestion
section above. It is committed because the mechanism is sound and the geometry is
derived rather than guessed, not because it is a win.

## Toolchain versions matter more than they look

`/opt/openxc7` shipped yosys 0.62 and nextpnr 0.9.2, while openXC7's own
`toolchain-installer` pins **yosys v0.68** and **nextpnr-xilinx 0.9.3** — the
installed copy had simply never been refreshed. `build.sh` now prefers locally
built newer versions; explicit `YOSYS=`/`NEXTPNR=` still win.

Two bugs chased during this work turned out to be **already fixed upstream** (a
nextpnr control-set bug, and a `synth_xilinx` split-run bug fixed after v0.68).
A stale tree reproduces its own bugs perfectly, so check upstream before
diagnosing — and check the meta-repo that pins versions, not just the tool repos.

Upgrading yosys 0.62 -> 0.68 changes the netlist (~1500 fewer small LUTs; MUXF7
unchanged at ~292), so **figures either side of that boundary are not
comparable**. Re-baseline rather than carrying old numbers forward.
