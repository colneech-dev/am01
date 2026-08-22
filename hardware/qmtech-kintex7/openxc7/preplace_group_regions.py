"""
nextpnr --pre-place hook: confine every cell to a region for its RTL group.

Supersedes preplace_round_regions.py, which keyed on a round index and so could
only reach 51621 of 71632 cells (72%). This keys on durable RTL hierarchy and
reaches 69975 of 69975 (100%), including groups the round version could not see
at all -- the three keccak cores and the GPIO wrapper among them.

WHY GROUPS, NOT ROUNDS
----------------------
The 18354 cells the round heuristic missed were not badly-parsed round logic;
they were a different part of the design (GPIO wrapper, control, the nonce
adder). Forcing them into a round region would have been wrong, and neighbour
propagation would have done exactly that to 52% of them. Every cell needs a
group, but not every cell belongs to a round.

WHY THIS KEYS ON RTL PATHS
--------------------------
Vivado can supply an exact site for all 70011 cells, but keyed on yosys cell
names, which are pure counters:

    $abc$493613$auto$blifparse.cc:557:parse_blif$493614

tools_name_churn_test.sh measures the cost: two modules differing by ONE unrelated
gate share ZERO cell names, because the ABC counter shifted and renamed
everything -- including untouched cells. Such a map is a snapshot of one netlist.

RTL hierarchy does not churn ('crypter.round14.sboxes.sbox35inst' comes from the
source, verified identical across files at 1260/1260 sbox paths), so a floorplan
keyed on it survives rebuilds. Use Vivado's placement to LEARN the geometry, then
express it here.

ANCHORING
---------
A group's box is derived from those of its own cells that already have a fixed
BEL -- in practice the BRAMs placed by floorplan_stripe.py. Groups with no such
anchor (keccak, wrapper, control) are left FREE rather than boxed at an invented
location: an unanchored box would be a guess, and a wrong guess constrains the
placer harder than no constraint at all.

USAGE
    nextpnr-xilinx ... --pre-place preplace_group_regions.py
    (env) GROUP_MAP  path to cell_groups.json  [out_nm1_nosr/cell_groups.json]
    (env) GROUP_PAD  tiles of padding around each anchored bbox  [default 12]
    (env) GROUP_MIN  skip groups smaller than this  [default 64]
"""
import json
import os
import sys
from collections import defaultdict

GROUP_MAP = os.environ.get("GROUP_MAP", "out_nm1_nosr/cell_groups.json")
PAD = int(os.environ.get("GROUP_PAD", "12"))
MIN_CELLS = int(os.environ.get("GROUP_MIN", "64"))
DIAG = os.environ.get("GROUP_LOG", "preplace_regions.log")

# Diagnostics go to a FILE, not just stdout.
#
# The predecessor of this script printed everything to stdout, which nextpnr does
# not route into --log. The first region run was launched through a pipeline
# ending in `tail`, so stdout was buffered and never flushed -- and the hook
# turned out to have matched ZERO cells and done nothing at all. Both runs of the
# experiment came back bit-identical (wirelen solved = 3049217 in each) and I
# briefly read that null result as "regions hurt timing". A hook that cannot
# report what it did is worse than no hook.
_diag = open(DIAG, "w")


def say(msg):
    print(msg)
    _diag.write(msg + "\n")
    _diag.flush()


say("preplace_group_regions: reading %s" % GROUP_MAP)
cell_group = json.load(open(GROUP_MAP))
say("preplace_group_regions: %d cell->group entries" % len(cell_group))

# nextpnr has packed by now, so its cell set is not the synthesis netlist's.
# Report the overlap rather than assume it: a low match means the regions cover
# little and the run would say nothing about the idea being tested.
#
# Coerce the key with str(). The binding yields nextpnr IdString objects, and
# `idstring in dict_of_str` is False for every cell however correct the names
# are -- which is exactly how the first attempt matched nothing while looking
# like it had run.
import re

# nextpnr splits a LUT6 into LUT5 pairs during packing and names the halves after
# the cell they came from:
#
#     $flatten\...crypter.round3...S[5]$LUT$1492
#
# The parent is still in the name, so these are recoverable -- and they are real
# datapath logic, so leaving them unconstrained would be a hole in the floorplan
# exactly where it matters. 478 cells on this design.
SPLIT_SUFFIX = re.compile(r"\$LUT\$\d+$")

# $PACKER_GND_NET$..., $PACKER_VCC_NET$... are constant/tie drivers nextpnr
# invents. They have no RTL parent and no natural home; boxing them would
# constrain the placer for no benefit. Left free on purpose, not by omission.
PACKER_RE = re.compile(r"^\$PACKER_")

present = {}
n_ctx = 0
sample_keys = []
recovered = 0
packer = 0
unmatched_other = []
for cname, cell in ctx.cells:  # noqa: F821  (ctx injected by nextpnr)
    n_ctx += 1
    key = str(cname)
    if len(sample_keys) < 3:
        sample_keys.append(key)
    g = cell_group.get(key)
    if g is None and not PACKER_RE.match(key):
        # Try the pre-split parent name.
        parent = SPLIT_SUFFIX.sub("", key)
        if parent != key:
            g = cell_group.get(parent)
            if g is not None:
                recovered += 1
    if g is not None:
        present[key] = g
    elif PACKER_RE.match(key):
        packer += 1
    elif len(unmatched_other) < 5:
        unmatched_other.append(key)
frac = 100.0 * len(present) / max(1, n_ctx)
say("preplace_group_regions: matched %d of %d nextpnr cells (%.1f%%)"
    % (len(present), n_ctx, frac))
say("  recovered via pre-split parent name : %d" % recovered)
say("  $PACKER tie cells, left free on purpose: %d" % packer)
say("  sample nextpnr keys: %s" % sample_keys)
say("  sample map keys    : %s" % list(cell_group)[:3])
if unmatched_other:
    # Anything here is a genuine gap rather than an expected packing artefact,
    # so name it instead of letting it hide inside a percentage.
    say("  UNEXPECTED unmatched (not packer, not a split): %s" % unmatched_other)

# Refuse to continue silently on a null match. A no-op hook produces a run
# indistinguishable from the control, which reads as a clean experimental result
# rather than as the broken instrumentation it is.
if not present:
    say("preplace_group_regions: FATAL -- matched 0 cells; names do not join.")
    _diag.close()
    sys.exit(1)

members = defaultdict(list)
for cname, g in present.items():
    members[g].append(cname)

def bel_attr(cell):
    """The cell's BEL constraint string, or None.

    Read the ATTRIBUTE, not cell.bel. --pre-place runs before ctx->place(), and
    place_constraints() -- which turns this attribute into an actual binding --
    is the first thing the HeAP placer does. So at hook time NOTHING is bound
    and cell.bel is unset for every cell, including the floorplan's BRAMs.

    The first version read cell.bel and therefore found 0 anchors out of 173
    groups, created 0 regions, and produced a run bit-identical to the control
    while reporting success.

    Iterate the attribute map rather than indexing it. Indexing a missing key
    raises from C++ through boost::python, which surfaces as

        terminate called without an active exception

    i.e. SIGABRT, not a catchable Python exception -- so `try: a["BEL"]` does not
    protect anything. Only cells carrying the floorplan's BEL attribute have the
    key, which is the overwhelming minority, so the second version aborted the
    run almost immediately.
    """
    try:
        for k, v in cell.attrs:  # noqa: F821
            if str(k) == "BEL":
                s = str(v)
                # getBelLocation parses this as a bel name; anything without a
                # '/' is not one, and feeding it in would abort the same way.
                return s if "/" in s else None
    except Exception:
        return None
    return None


def robust_range(vals):
    """min/max after discarding outliers by the 1.5*IQR rule.

    A plain min/max is at the mercy of a single stray anchor. Measured: round0
    came out with 21 anchors where every other round had 20, and a box 227 tiles
    tall against ~40 for the rest -- so its logic was effectively unconstrained
    while appearing to be handled. The extra anchor is a clock or IO cell, which
    carries a BEL constraint from the pinout XDC and sits nowhere near the round's
    BRAMs.

    Rejecting by spread rather than by cell type keeps this design-independent:
    it does not need to know which cell types are 'real' anchors.
    """
    s = sorted(vals)
    n = len(s)
    if n < 4:
        return s[0], s[-1], 0
    q1 = s[n // 4]
    q3 = s[(3 * n) // 4]
    iqr = q3 - q1
    lo, hi = q1 - 1.5 * iqr, q3 + 1.5 * iqr
    keep = [v for v in s if lo <= v <= hi]
    if not keep:
        return s[0], s[-1], 0
    return min(keep), max(keep), n - len(keep)


# Anchor locations per group, from whichever of its cells carry a BEL constraint.
anchor_locs = defaultdict(list)
for g, names in members.items():
    for cname in names:
        cell = ctx.cells[cname]  # noqa: F821
        bn = bel_attr(cell)
        if not bn:
            continue
        try:
            # Bound with conv_from_str<BelId>, so the bel NAME string works
            # directly -- which is exactly what the BEL attribute holds
            # (e.g. "RAMB18_X1Y18/RAMB18E1").
            loc = ctx.getBelLocation(bn)  # noqa: F821
        except Exception:
            continue
        anchor_locs[g].append((loc.x, loc.y))

bbox = {}
anchors = defaultdict(int)
rejected_total = 0
for g, locs in anchor_locs.items():
    xs = [p[0] for p in locs]
    ys = [p[1] for p in locs]
    x0, x1, rx = robust_range(xs)
    y0, y1, ry = robust_range(ys)
    bbox[g] = [x0, y0, x1, y1]
    anchors[g] = len(locs)
    rejected_total += rx + ry
say("preplace_group_regions: discarded %d outlying anchor coordinates (1.5*IQR)"
    % rejected_total)

say("preplace_group_regions: %d of %d groups have an anchor" % (len(bbox), len(members)))

# A run with no anchors constrains nothing and is indistinguishable from the
# control -- which reads as a clean null result rather than as a broken hook.
# That has now happened twice (once from an IdString/str key mismatch, once from
# reading cell.bel before anything was bound), so fail instead of proceeding.
if not bbox:
    say("preplace_group_regions: FATAL -- 0 anchors; no region can be derived.")
    say("  Anchors come from cells carrying a BEL attribute (the floorplan's")
    say("  BRAMs). If the floorplan step did not run, there is nothing to anchor")
    say("  to and this hook cannot place anything.")
    _diag.close()
    sys.exit(1)

constrained = 0
skipped_small = skipped_free = 0
made = 0
region_boxes = {}   # region name -> [x0, y0, x1, y1], for the reusable dump
cell_region = {}    # cell name   -> region name
for g, names in sorted(members.items(), key=lambda kv: -len(kv[1])):
    if len(names) < MIN_CELLS:
        skipped_small += len(names)
        continue
    if g not in bbox:
        # No anchor -- leave free. Boxing it somewhere invented would constrain
        # the placer with a guess, which is worse than not constraining it.
        skipped_free += len(names)
        continue
    b = bbox[g]
    x0, y0 = max(0, b[0] - PAD), max(0, b[1] - PAD)
    x1, y1 = b[2] + PAD, b[3] + PAD
    rname = "grp%d" % made
    ctx.createRectangularRegion(rname, x0, y0, x1, y1)  # noqa: F821
    region_boxes[rname] = [x0, y0, x1, y1]
    made += 1
    ok = 0
    for cname in names:
        try:
            ctx.constrainCellToRegion(cname, rname)  # noqa: F821
            cell_region[cname] = rname
            ok += 1
        except Exception:
            pass
    constrained += ok
    say("  %-56s %5d cells  x %3d..%-3d y %3d..%-3d  (%d anchors)"
        % (g[-56:], ok, x0, x1, y0, y1, anchors[g]))

say("preplace_group_regions: %d regions, %d cells constrained" % (made, constrained))
say("  left free (no anchor): %d cells" % skipped_free)
say("  left free (group < %d): %d cells" % (MIN_CELLS, skipped_small))

# Dump the computed floorplan in the form nextpnr can now read directly from a
# design file (see apply_region_constraints() in common/place_common.cc).
#
# The boxes can only be computed in here, because turning a BEL name like
# "RAMB18_X1Y18/RAMB18E1" into tile coordinates needs the chipdb. But once
# computed they are just numbers, so baking them into the JSON removes the
# dependency on Python bindings entirely -- which is what makes this usable on a
# stock nextpnr rather than only on a build with bindings plus the local
# getBelLocation patch.
spec_path = os.environ.get("GROUP_SPEC", "regions_spec.json")
try:
    spec = {
        "nextpnr_regions": ";".join(
            "%s:%d,%d,%d,%d" % (rn, b[0], b[1], b[2], b[3]) for rn, b in region_boxes.items()
        ),
        "cell_region": cell_region,
    }
    with open(spec_path, "w") as fh:
        json.dump(spec, fh)
    say("  wrote reusable floorplan to %s (%d regions, %d cells)"
        % (spec_path, len(region_boxes), len(cell_region)))
except Exception as e:
    say("  could not write %s: %s" % (spec_path, e))
