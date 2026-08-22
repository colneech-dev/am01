# nextpnr-xilinx router2: two thread-safety gaps in the backward-BFS fast path

> **RE-CHECKED 2026-08-23 — do not pitch bug 2 upstream; it is already fixed.**
>
> Bug 1 (ours) is gone: `N_RETRY_THREADS` no longer appears in `router2.cc`, so
> the unsafe hard-tail parallelisation is reverted as described below.
>
> Bug 2 (the "stock gap") was **already fixed upstream** by David Shah in
> `c42f87b3 router2: Make splitting of wires thread-safe`, dated 2020-12-01 —
> nearly six years before this writeup. It arrived here with the 25-commit merge
> from openXC7 HEAD. The guard now present at `router2.cc` ~1073 and ~1240 is
> his, not ours.
>
> This is the fourth item in this campaign written up as an upstream candidate
> that turned out to be already fixed there (the others: a nextpnr control-set
> bug, a `synth_xilinx` split-run bug fixed after v0.68, and an SRL routing
> failure). A stale tree reproduces its own bugs perfectly. **Check upstream
> before writing up, not after.**
>
> Retained because the analysis of the exclusion model is still accurate and
> useful: `thread_test_wire()`'s bbox containment is the only thing making
> concurrent `flat_wires[]` access safe, so concurrent threads must have
> disjoint bounding boxes. That invariant is what
> `router2_mt_partition.proposed.cc` reasons from.


> **STATUS: fix implemented and validated locally, ready to pitch upstream.**
> Written up 2026-08-16 during `NUM_MINERS=1` openXC7 P&R bring-up on
> `claude/openxc7-sync-only-dff`, while chasing an `Assertion failure:
> cursor_fwd == dst_wire_idx` crash in `router2.cc:845`. One of the two bugs
> below is in our own local fork (a well-intentioned but unsafe
> parallelization patch); the other is a small, genuine gap in stock
> nextpnr-xilinx's thread-exclusion model. See
> `nextpnr-xilinx-control-set-bug.md` for the sibling FF-packing writeup from
> the same bring-up.

## Summary

`router2`'s multithreading model has exactly one exclusion mechanism:
`thread_test_wire(t, w)`, which returns `w.x/y` inside `t.bb` -- i.e. each
thread only touches wires inside a bounding box nobody else's `t.bb`
overlaps. There is no lock anywhere in the file. That works *only* as long
as every codepath that reads or mutates `flat_wires[...]` is gated behind
that check, and as long as every thread's `t.bb` is actually disjoint from
every other running thread's `t.bb`. Both of those held only partially:

1. **Local fork bug**: a hard-tail parallelization patch we added gave
   `N_RETRY_THREADS` concurrent `ThreadContext`s the *same* unbounded
   full-chip `t.bb` each, on the theory that "`is_mt` only controls
   retry-without-bbox behaviour, which is moot once the bbox is already
   unbounded." That reasoning missed that `thread_test_wire`'s bbox check is
   the *only* thing making concurrent access to `flat_wires` safe at all --
   with identical unbounded boxes, the check always passes and provides zero
   exclusion between the threads. This is what actually caused the crash
   (confirmed below).
2. **Stock gap**: independent of (1), `route_arc()`'s backward-BFS "tack onto
   existing routing" merge-check (`router2.cc`, in the `if
   (cwd.bound_nets.count(net->udata))` block) reads and walks
   `flat_wires[...].bound_nets` without ever calling `thread_test_wire()` --
   unlike the uphill-exploration loop nine lines below it, which guards every
   wire it touches before reading it. This walk follows a net's own
   already-bound pips, which is *usually* local to the calling thread's bbox
   but isn't bounded by anything that guarantees it. This one wasn't proven
   to be the actual trigger for our crash, but it's a real gap in the
   existing safety model and worth closing regardless.

## Empirical confirmation (not just code reading)

On the `NUM_MINERS=1` design (~1.4M wires, seed 7), every multithreaded P&R
attempt crashed identically and near-instantly:

```
Info: Running main router loop...
terminate called after throwing an instance of 'nextpnr_xilinx::assertion_failure'
  what():  Assertion failure: cursor_fwd == dst_wire_idx (common/router2.cc:845)
```

- Same seed, same everything, rerun as a fresh process (v5 → v6): **identical
  crash**, identical placement checksum, identical failure point. Rules out
  ordinary timing-window nondeterminism as the *only* explanation, but is
  fully consistent with a race that resolves the same way every time under
  consistent OS scheduling on a lightly-loaded machine.
- Reverted our own small-queue threading threshold patch back to its
  original value, same seed (v7 → v8): **identical crash**. Ruled that patch
  out -- it only affects late-iteration small batches, and this crash
  happens on the very first, always-large iteration regardless.
- Reverted `--placer-heap-beta` back to default (v6 vs v7/v8, different
  placement checksums each time): **identical crash** in all cases. Ruled
  out placement/beta as the cause.
- Forced fully single-threaded routing via a temporary env-gated bypass
  (`NEXTPNR_ROUTER2_FORCE_SINGLETHREAD=1`, v9): **crash disappeared**. The
  run got past the exact point every multithreaded attempt died at and
  printed the iteration-1 congestion summary
  (`iter=1 wires=1399186 overused=136836 ...`) for the first time in this
  investigation.
- After reverting the hard-tail parallelization to serial (bug 1) and adding
  the merge-check guard (bug 2), full multithreaded routing (quadrant +
  vertical + horizontal threads all still concurrent, only the hard-tail
  stage serialized) is under test as of this writing.

## The fix

**Bug 1** (ours): reverted the hard-tail stage to serial. `hard_tail` nets
are, by definition, the ones that don't fit in any single quadrant/strip
bbox -- they can't be split into genuinely disjoint bounding boxes, so
`thread_test_wire`-style exclusion can't apply to them without a different
mechanism (e.g. a real per-wire atomic claim, not a bbox check). Safely
parallelizing this stage is a real, separate piece of future work, not a
quick patch.

**Bug 2** (stock): added a `thread_test_wire` check to the merge-check block,
bailing out of the fast-path merge attempt (falling through to ordinary
forward A*, which is already fully guarded) if the walk would leave the
calling thread's bbox. Low-risk, small diff, closes a real gap regardless of
whether it was the proximate cause here.

## Suggested upstream action

Bug 2 is a clean, small, self-contained fix worth a PR: add the missing
`thread_test_wire` guard to the merge-check block in `route_arc()`
(`common/router2.cc`), mirroring the existing pattern already used nine
lines below it. No behavioural change when single-threaded; only prevents an
out-of-bbox read during multithreaded routing.

Bug 1 is fork-local (our own hard-tail parallelization was never upstream)
and doesn't need reporting -- just documented here so the reasoning error
("unbounded bbox makes is_mt a no-op") doesn't get repeated if that
optimization is revisited with a proper per-wire ownership mechanism later.
