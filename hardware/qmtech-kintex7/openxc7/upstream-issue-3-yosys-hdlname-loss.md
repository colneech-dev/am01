# yosys: cell provenance (`hdlname`) is lost through synthesis, leaving 99.4% of a netlist unattributable

**Target:** [YosysHQ/yosys](https://github.com/YosysHQ/yosys) — feature request / defect
**Measured with:** yosys 0.62 (git sha1 7326bb7d6), `synth_xilinx -family xc7 -flatten`
**Design:** OdoCrypt miner, xc7k325t, 69,869 cells

## Summary

After `synth_xilinx`, **no** cell in the datapath carries any attribute linking it
back to the RTL that produced it. `hdlname` is absent, and `src` has been
overwritten with the techmap file. Hierarchy information *is* still emitted —
1,657 `$scopeinfo` cells record the module tree — but nothing connects individual
cells to it.

The practical consequence: any downstream tool that wants to act per-RTL-module
(floorplanning, region constraints, incremental P&R, physical grouping,
per-module timing attribution) has no supported way to do so.

## Measurements

Attribute coverage on the synthesised netlist:

| cell type | total | `hdlname` | `src` |
|---|---|---|---|
| LUT6 | 19,406 | **0** | 19,406 |
| LUT2 | 13,732 | **0** | 13,732 |
| LUT3 | 7,216 | **0** | 7,216 |
| FDRE | 27,607 | **0** | 27,607 |
| RAMB18E1 | 420 | **0** | 420 |
| MUXF7 | 294 | **0** | 294 |
| CARRY4 | 99 | **0** | 99 |

`src` is present but useless for attribution — it points at the techmap source,
so all 19,406 LUT6s share one value:

```
/opt/openxc7/bin/../share/yosys/xilinx/lut_map.v:43.26-44.30
/opt/openxc7/bin/../share/yosys/xilinx/lut_map.v:61.26-63.41
```

By cell name, the netlist is 99.4% anonymous:

| name kind | count |
|---|---|
| `$abc$…parse_blif$N` | 41,809 |
| `$auto$ff.cc:337:slice$N` | 27,614 |
| hierarchical | 423 |

## The loss happens before ABC, not in it

`hdlname` survives only on objects that already carry RTL names. Of 26,551 nets:

```
auto-generated names        20,829
  ...of those with hdlname       0
nets with hdlname            5,704   (all already hierarchically named)
```

So `hdlname` is present exactly where it is redundant, and absent everywhere it
would add information. Internal wires created by `flatten`/`opt`/`techmap` do not
inherit it, so by the time ABC runs the provenance is already gone.

This matters for where a fix belongs: patching `abc.cc` alone would propagate
nothing, because the cone ABC consumes is already unattributed.

## Why the information is genuinely still available

`passes/techmap/abc.cc` resolves every ABC-created cell back to the original
RTLIL wire it drives:

```cpp
// remap_name(), abc.cc:591
const auto &bit = signal_bits.at(sid);
if (bit.wire != nullptr) {
    std::string s = stringf("$abc$%d$%s", map_autoidx, bit.wire->name.c_str()+1);
    ...
    if (orig_wire != nullptr)
        *orig_wire = bit.wire;
```

and already stamps a grouping attribute at every `addCell`:

```cpp
RTLIL::Cell *cell = module->addCell(remap_name(c->name), ID($_NOT_));
if (markgroups) cell->attributes[ID::abcgroup] = map_autoidx;
```

So the mechanism and the back-pointer both exist. What is missing is that the
earlier passes do not put anything on the wire worth propagating.

## Suggested fix

Propagate `hdlname` (or an equivalent scope attribute) when a pass creates a cell
or wire derived from existing ones — at minimum in `flatten`, `opt_*`, `techmap`
and `abc`. Cells produced from a cone could inherit the common prefix of the
`hdlname`s of the cells they replace; where the cone spans scopes, the shared
ancestor is still far more useful than nothing.

Backwards-compatible: it only adds attributes.

## Workaround, for anyone hitting this now

Net *names* survive where cell attributes do not, because `flatten` encodes the
hierarchy into them:

```
$\odocrypt_gpio_wrapper_inst.g_miner[0].miner_top_inst.miner.worker.crypt.
    crypter.round0.sboxes.sbox0inst.mem$rdreg[0]$d
```

Walking each cell's connected nets and taking the deepest RTL-identifier prefix
recovers a group for **100%** of cells (69,975/69,975 on this design). Two
cautions learned the hard way:

1. **Discard nets named with more than one scope.** One global signal threaded
   through every round's hierarchy pulled 8,786 unrelated cells into round 0,
   inflating it to 11,214 against a true 2,428.
2. **Do not infer from neighbours.** 52% of otherwise-unresolvable cells would
   take a scope from an adjacent cell, but a comparator reading the last round's
   output is not part of that round.

This workaround is only necessary because the attributes are missing; it should
not be the supported path.

## Why cell names cannot substitute

Cell names are built from pass-internal counters:

```
$abc$493613$auto$blifparse.cc:557:parse_blif$493614
      ^^^^^^        ^^^^^^^^^^^^^^^^^^^^^^^  ^^^^^^
      ABC counter   yosys source file:line   autoidx
```

Two modules identical except for one extra, unrelated gate:

```
v1 abc-named cells : 15
v2 abc-named cells : 17
names in BOTH      :  0
```

The ABC counter moved 1611 → 1613 and renamed every cell, including the 15 whose
logic was untouched. Anything keyed on cell names is invalidated by any edit,
which is precisely why an attribute is needed.

Reproducer: `tools_name_churn_test.sh` in this directory.
