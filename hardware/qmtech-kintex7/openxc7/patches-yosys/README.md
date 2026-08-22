# yosys patches

Candidates for upstream submission to [YosysHQ/yosys](https://github.com/YosysHQ/yosys).
Built and tested against yosys 0.62 (git sha1 7326bb7d6).

Together with `../patches/` (nextpnr) these give hierarchy-aware placement from
stock tools: **yosys produces the provenance, nextpnr consumes it.** Either alone
is useless.

## `hdlname_recover.cc` + `0001-register-hdlname-recover.patch`

A new pass that restores the `hdlname` attribute on cells that lost it during
synthesis, deriving each cell's RTL scope from the names of the nets it touches.

### The problem it solves

After `synth_xilinx -flatten`, essentially no cell can be traced to the RTL that
produced it. Grouping the cells that lack `hdlname` on a 70k-cell xc7 design by
the pass that created them:

| pass | cells |
|---|---|
| `blifparse.cc` (abc) | 41,809 |
| `ff.cc` | 27,614 |
| hierarchical | 423 |
| `alumacc.cc` | 33 |
| `iopadmap` | 29 |
| `clkbufmap.cc` | 1 |

nextpnr reports the consequence directly:

```
Info: Hierarchy floorplan: 2 of 70774 cells carry hdlname.
```

Two real cells. (A `hdlname` count from the JSON looks like 1,657, but every one
is a `$scopeinfo` marker rather than a cell — worth knowing before using that
number as a success criterion.)

`src` survives but is useless for attribution: techmap overwrites it with its own
file, so all 19,406 LUT6s share `techlibs/xilinx/lut_map.v:43`. That is **not**
techmap's fault — it appends correctly via `add_strpool_attribute` — it is
preserving a chain that was never populated.

Cell names are no substitute, being pass-internal counters
(`$abc$493613$auto$blifparse.cc:557:parse_blif$493614`). Two modules differing by
one unrelated gate share **zero** cell names, because the ABC counter shifts and
renames everything including untouched cells (`../tools_name_churn_test.sh`).

So anything wanting to act per RTL module — floorplanning, region constraints,
incremental P&R, per-module timing attribution — has nothing to key on.

### Why recovery rather than propagation

The obvious fix is for each pass to propagate `hdlname` when it creates a cell.
That was tried first, in `abc.cc`, where the machinery already exists — the wire
re-integration loop resolves each new wire back to its original and copies `src`.
**It does not work**, and the reason is worth recording:

```
nets 37 | with hdlname 5 | with src 34
hdlname nets: u_mid.a, u_mid.b        <- module PORT nets only
```

Only the boundary nets `flatten` renames carry `hdlname`. ABC's cells drive
*internal* nets, which have none, so there is nothing to propagate. ABC cells
also already receive `src`. The patch was reverted as entirely redundant.

The hierarchy lives in the **names**, not the attributes — which is what this
pass reads.

### Measured

Small hierarchical design (`top -> u_mid -> u_inner`), flattened:

```
Module top: set hdlname on 48 cell(s) (20 from an output net, 28 from an input net).
  11 cell(s) touch no net with a recoverable scope.
  1 cell(s) already had hdlname and were left alone.

  u_mid u_inner    40 cells     <- the inner XOR/AND cone
  u_mid             8 cells     <- the outer rotate-xor
```

against **0** for the propagation approach. The split matches the RTL structure.

A Python prototype of the same algorithm resolved 69,975/69,975 cells on the
70k-cell design, with round-level groups uniform at ~2,427 cells across 21
identical pipeline rounds, cross-checked against an independent derivation.

### Two correctness rules, both learned the hard way

* **Output nets first.** An input net may belong to the previous stage and would
  attribute the cell backwards.
* **Nets naming more than one scope are ignored.** Global signals threaded
  through every instance attribute cells at random — in the measured design a
  single such net pulled **8,786** unrelated cells into one scope.

## `0002-synth-xilinx-luts-option.patch`

Adds `-luts <costs>` to `synth_xilinx`, exposing the LUT area cost tuple that is
otherwise hardcoded as `2:2,3,6:5,10,20`.

### Why it is wanted

On the OdoCrypt design the hardcoded tuple makes abc prefer LUT6+LUT2 (two logic
levels, two general-routing hops) over LUT7 (2xLUT6 + a MUXF7, one hop) wherever
it sees slack: the shipped netlist has 13,732 LUT2 and only 294 MUXF7, where the
640-bit x 21-round rotation network predicts ~13,440.

**The default is deliberately NOT changed.** It is not obviously wrong: a LUT2 can
share a 6-LUT site via O5/O6, so pricing it at 2 rather than 5 is a defensible
packing heuristic, and abc already knows LUT7 is depth 1 against LUT6+LUT2's
depth 2 — it takes the deeper form only where it believes there is slack.

The real weakness is that `abc.cc` writes the delay column as a constant:

```c
fprintf(f, "%d %d.00 1.00
", i+1, config.lut_costs.at(i));
```

so a unit-delay model cannot express that on this fabric an extra logic level
costs a routing hop (~1.3 ns measured) dwarfing the LUT delay itself. That is
what `abc9` exists for and is not a one-line change.

This patch only makes the tuple reachable, so the measurement that would justify
changing a default is possible at all. Additive: without `-luts`, behaviour is
byte-identical.

### Confirmed still missing upstream

Checked against `YosysHQ/yosys` main: the `-luts` tuple is displayed in help mode
but is not exposed as a user-configurable parameter; only the abc9 `-W` weight is
settable via the scratchpad.

## Withdrawn: `-run map_luts:` with `-abc9` emitting unmapped flip-flops

In yosys 0.62, `ff_map.v` was invoked from two mutually exclusive places —
`if abc9` in `map_ffs` and `if !abc9` in `map_luts` — so `-abc9 -run map_luts:`
fired neither and completed "successfully" with `$_SDFFE_*` cells left in the
netlist, which then failed much later in place-and-route.

**Already fixed upstream.** Current main has exactly one invocation, unconditional:

```
run("dfflegalize -cell $_DFFE_?P?P_ 01 -cell $_SDFFE_?P?P_ 01 -cell $_DLATCH_?P?_ 01", ...);
run("techmap -map +/xilinx/ff_map.v");
```

The patch was written against 0.62 and has been reverted rather than submitted.
This is the second change today that turned out to be already fixed upstream —
the first was a nextpnr control-set bug (`bf78fccf`).

## Version currency

These were developed against **yosys 0.62**; upstream is at **0.68**, six
releases ahead. The local tree is not a git checkout, so it could not be diffed
directly — the checks above were made against raw sources on `main`. Rebase onto
current main before submitting; `hdlname_recover.cc` is a new file and should
apply anywhere, but `0002` is a context diff against 0.62.

## Not submitted

An `abc.cc` change propagating `src`/`hdlname` onto ABC-created cells was written
and reverted: measured to have no effect, for the reasons above. Kept out rather
than shipped as a no-op.
