# nextpnr-xilinx control-set contention — RESOLVED (diagnosis was wrong)

> **STATUS: RESOLVED. Do not file this upstream.** The original writeup
> (2026-08-16) blamed `pack_ffs()` for not enforcing half-slice control-set
> compatibility. An independent review of the packing code on 2026-08-21 showed
> that claim is false, and that the real cause had already been fixed in this
> tree thirteen days *before* the writeup was made. Kept as a record so the
> reasoning is not lost and nobody re-derives it.

## The observed symptom (this part was real)

FASM export aborts after a complete place-and-route:

```
ERROR: FASM: FF '<name>' (type FDRE) at bel SLICE_XxYy/xFF disagrees with its
half-slice on '<attr>' (tile <tile>) -- control-set contention in the placement
```

Costly because it surfaces only at the very end, after synthesis, packing,
placement and routing have all completed, with no recovery path.

## What the original writeup claimed — and why it is wrong

It claimed nothing in packing or placement checks half-slice control-set
compatibility, and that `write_ffs_config()` (`xilinx/fasm.cc`) is the only place
it is ever validated.

That is not what the source does. `Arch::xc7_logic_tile_valid`
(`xilinx/arch_place.cc:811-874`) checks, per half-slice: `clk`, `sr`, `ce`,
`is_clkinv`, `is_srinv`, `is_latch`, `ffsync`. The bel indices match the FASM
writer exactly (`BEL_FF2 == BEL_FF+1 == 0x3`, `arch.h:87-88`), and
`updateLogicBel` marks `halfs[(z>>4)/4].dirty` on every FF bind
(`arch.h:794-798`), so the cache cannot go stale.

That check is **strictly stronger** than the FASM-time one — it compares net
identity, where fasm compares derived `is_srused`/`is_ceused` flags — so it
cannot be the source of a FASM-only failure.

## The actual mechanism

The **frozen-tile fast path** at `arch_place.cc:336-367`, which returned `true`
with no checks at all for tiles whose cells were all at or above a strength
threshold. Fixed by:

```
bf78fccf  2026-08-03  xc7: restore real slice validation for placer-constrained tiles
```

which narrowed that threshold from `STRENGTH_STRONG` to `STRENGTH_USER`. Its
commit message describes exactly the symptom above:

> "HeAP's legalise_placement_strict binds every chain with STRENGTH_STRONG… any
> tile filled by a carry chain or mux tree was mistaken for a frozen Vivado
> import and skipped validation entirely — the legaliser's own
> isBelLocationValid() became vacuous."

Verified present in this tree: `git merge-base --is-ancestor bf78fccf HEAD` → yes.

**So the diagnosis was made against behaviour that had already been fixed**, and
would have sent maintainers to `pack_ffs()`, which was never the problem.

## Residual hole (real, but inert in the open flow)

The fast path still skips **all** validity checks for a tile in which every cell
is `STRENGTH_USER`. `STRENGTH_USER` is set only by `place_constraints()` for
cells carrying a JSON `BEL` attribute (`placer_heap.cc:410,437`), and HeAP itself
binds at `STRENGTH_WEAK`/`STRENGTH_STRONG`. So in a pure `--placer heap` flow it
never fires — but it is live for an imported placement, and now also for our own
BRAM floorplanning, which pins 420 cells at `STRENGTH_USER`. BRAM tiles carry no
LUT-packing or control-set rules, so this is believed harmless there.

## Open item: the workaround may now be unnecessary

`synth_fdre_only.ys:40` still carries:

```
dfflegalize -cell $_SDFFE_?P0P_ 01 -cell $_DLATCH_?P?_ 01 -minsrst 999999999 -mince 999999999
```

Those thresholds force **every** reset and clock-enable into LUT logic — confirmed
in the bitstream, where `SRUSEDMUX` and `CEUSEDMUX` counts are both 0 across
27,607 FDREs. If `bf78fccf` removed the real cause, this is spending LUTs for
nothing. **Not yet tested** (deliberately deferred). One build without the
`-minsrst`/`-mince` overrides settles it.

## Related genuine bugs found during the same investigation

These are real, verified, and upstream — see the GitHub issues filed 2026-08-21:

- `--placer-heap-alpha` / `--placer-heap-beta` silently discarded by
  `Arch::place()` (upstream since `c9b9cab7`, 2020-02-13)
- `router2` closes a wire on first *push* rather than first *pop*, making the
  cost-relaxation branch dead code (upstream since `2de98386`, 2020-01-14)
