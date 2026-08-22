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

## `0002-synth-xilinx-ffmap-and-luts.patch`

Two independent changes to `synth_xilinx`; split before submitting.

### (a) `-run map_luts:` with `-abc9` silently emits unmapped flip-flops

`ff_map.v` is invoked from two mutually exclusive places:

```
map_ffs  (~632):  techmap -map +/xilinx/ff_map.v    if  abc9
map_luts (~687):  techmap -map +/xilinx/ff_map.v    if !abc9
```

Each is right for a full run. But `-abc9 -run map_luts:` skips the first (its
stage never executes) and guards off the second, so neither fires: synthesis
reports success with `$_SDFFE_*` cells still in the netlist, which then fail in
the place-and-route tool with an error pointing nowhere near the cause.

Splitting the run is not exotic — it is how you substitute a different `abc`
invocation, which is exactly what (b) exists to avoid needing.

Fix: run it unconditionally in `map_luts`. Idempotent, since after a previous
`ff_map` there are no `$_DFF_`/`$_SDFFE_` cells left for its rules to match.

### (b) `-luts <costs>` to override the LUT area costs

The tuple is hardcoded as `2:2,3,6:5,10,20`. On the OdoCrypt design that makes
abc prefer LUT6+LUT2 (two logic levels, two general-routing hops) over LUT7
(2×LUT6 + a MUXF7, one hop) wherever it sees slack: the shipped netlist has
13,732 LUT2 and only 294 MUXF7, where the 640-bit × 21-round rotation network
predicts ~13,440.

**The default is deliberately not changed.** It is not obviously wrong: a LUT2
can share a 6-LUT site via O5/O6, so pricing it at 2 rather than 5 is a
defensible packing heuristic, and abc already knows LUT7 is depth 1 against
LUT6+LUT2's depth 2 — it takes the deeper form only where it believes there is
slack.

The real weakness is that `abc.cc` writes the delay column as a constant:

```c
fprintf(f, "%d %d.00 1.00\n", i+1, config.lut_costs.at(i));
```

so a unit-delay model cannot express that on this fabric an extra logic level
costs a routing hop (~1.3 ns measured) dwarfing the LUT delay itself. Fixing that
properly is what `abc9` is for.

This just makes the tuple reachable, so the measurement that would justify
changing a default is possible without hand-rolling the flow — which is precisely
the split-run case that (a) fixes. Additive: without `-luts`, behaviour is
byte-identical.

## Not submitted

An `abc.cc` change propagating `src`/`hdlname` onto ABC-created cells was written
and reverted: measured to have no effect, for the reasons above. Kept out rather
than shipped as a no-op.
