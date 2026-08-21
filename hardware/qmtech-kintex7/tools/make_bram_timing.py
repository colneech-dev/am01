#!/usr/bin/env python3
"""
Build a block RAM timing database keyed by the cell names synthesis emits.

prjxray measures RAMB18 timing, but files it under mode-suffixed names on
the RAMBFIFO36E1 site (RAMBFIFO36E1RAM_MODE_U_RAMB18TDP_U_DOA_REG_U_0_...).
yosys emits plain RAMB18E1, so nothing ever finds it. This extracts the
arcs for the mode this design actually uses -- RAMB18 true dual port,
optional output register disabled -- and re-emits them under RAMB18E1 and
RAMB36E1, plus a C++ header carrying the same numbers.

Everything here is extracted, never typed in by hand: if the source data
changes, or you drop in real Kintex-7 SDF from DS182, re-running picks the
new values up. Every extraction is asserted, so a source-format change
fails loudly instead of silently emitting defaults.

See ../openxc7/make-bram-timing-db.sh for provenance and limits.
"""
import argparse, os, re, sys

# SDF delay triples are (min::max)(min::max): fast corner then slow corner.
# Static timing wants the pessimistic end -- the slow-corner max.
TRIPLE = r'\(([-0-9.]*)::([-0-9.]*)\)'


def parse_cells(text):
    """Yield (celltype, body) for every (CELL ...) in an SDF file."""
    for m in re.finditer(r'\(CELL\s*\(CELLTYPE\s*"([^"]+)"(.*?)\n\s*\)\s*\n', text, re.S):
        yield m.group(1), m.group(2)


def slow_max(triples):
    """Second group's max -- the slow-corner worst case."""
    return float(triples[1][1])


def extract(src_dir, vivado_sdf=None):
    path = os.path.join(src_dir, "BRAM_L.sdf")
    if not os.path.isfile(path):
        sys.exit(f"ERROR: {path} not found")
    text = open(path).read()

    vals = {}
    for celltype, body in parse_cells(text):
        # RAMB18 true/simple dual port, output register off vs on.
        m = re.search(r'RAMB18(?:TDP|SDP)_U_DO[AB]_REG_U_([01])_', celltype)
        if m:
            io = re.search(r'\(IOPATH\s+CLKARDCLKU\s+DO[AB]DOU\s+' + TRIPLE + r'\s*' + TRIPLE, body)
            if io:
                t = [(io.group(1), io.group(2)), (io.group(3), io.group(4))]
                key = "clk_to_do_reg" if m.group(1) == "1" else "clk_to_do"
                vals.setdefault(key, slow_max(t))
        # Address setup/hold live on the unsuffixed site cell.
        if celltype == "RAMBFIFO36E1":
            for kind, key in (("SETUP", "addr_setup"), ("HOLD", "addr_hold")):
                mm = re.search(r'\(' + kind + r'\s+ADDRAU\s+\(posedge CLKARDCLKU\)\s+' + TRIPLE, body)
                if mm:
                    vals.setdefault(key, float(mm.group(2)))

    # Optional: override the unregistered clock->DO arc with REAL device data
    # extracted from Vivado (write_sdf on a routed checkpoint for this exact
    # part/speed grade). prjxray ships no kintex7 timing at all, so the rest of
    # this file necessarily comes from artix7 -- same primitive family, different
    # silicon. This one arc is the one on our critical path, so where a measured
    # value exists we prefer it and say so.
    #
    # Vivado emits plain RAMB18E1 celltypes with the mode as cell PROPERTIES,
    # not encoded in the celltype name the way prjxray does, so it needs its own
    # tiny parser rather than the mode-suffix regex above.
    if vivado_sdf:
        if not os.path.exists(vivado_sdf):
            sys.exit(f"ERROR: {vivado_sdf} not found")
        seen = {}
        # Vivado's delay form is (min:typ:max) with single colons, NOT prjxray's
        # (min::max). And Vivado declares (TIMESCALE 1ps) while prjxray SDF is in
        # ns, so the extracted value must be scaled or it lands 1000x out.
        # Vivado's delay form is (min:typ:max) with single colons, NOT prjxray's
        # (min::max). And Vivado declares (TIMESCALE 1ps) while prjxray SDF is in
        # ns, so the value must be scaled or it lands 1000x out. Refuse to guess:
        # the SDF spec's default is 1ns, and silently applying that to picosecond
        # data would give a plausible-looking but absurd number.
        head = open(vivado_sdf, errors="ignore").read(4000)
        tm = re.search(r'\(TIMESCALE\s+([0-9.]*)\s*(ps|ns)\s*\)', head)
        if not tm:
            sys.exit(f"ERROR: no TIMESCALE in {vivado_sdf} -- refusing to guess units")
        ts = float(tm.group(1) or 1.0) * (0.001 if tm.group(2) == "ps" else 1.0)
        cellpat = re.compile(r'CELLTYPE\s+"([A-Z0-9_]+)"')
        VTRIPLE = r'\(([-0-9.]+):([-0-9.]+):([-0-9.]+)\)'
        iopat = re.compile(r'\(IOPATH\s+(CLK\S+)\s+(DO\S+)\s+' + VTRIPLE)
        cur = None
        with open(vivado_sdf, errors="ignore") as f:
            for line in f:
                m = cellpat.search(line)
                if m:
                    cur = m.group(1)
                if cur == "RAMB18E1":
                    io = iopat.search(line)
                    if io:
                        k = (io.group(1), io.group(2), io.group(3), io.group(5))
                        seen[k] = seen.get(k, 0) + 1
        if not seen:
            sys.exit(f"ERROR: no RAMB18E1 CLK->DO IOPATH arcs found in {vivado_sdf}")
        # Every instance must agree; a spread means some BRAM is configured
        # differently and a single value would be wrong.
        delays = set((k[2], k[3]) for k in seen)
        if len(delays) != 1:
            sys.exit(f"ERROR: {len(delays)} distinct clk->DO delays in {vivado_sdf} "
                     f"-- cannot collapse to one value: {sorted(delays)}")
        lo, hi = delays.pop()
        measured = float(hi) * ts        # SDF units -> ns
        n = sum(seen.values())
        print(f"  Vivado override: clk->DO = {measured} ns "
              f"(was {vals.get('clk_to_do')} from {os.path.basename(path)}), "
              f"confirmed identical across {n} arcs")
        vals["clk_to_do"] = measured
        vals["clk_to_do_src"] = "vivado-measured"

    required = ("clk_to_do", "clk_to_do_reg", "addr_setup", "addr_hold")
    missing = [k for k in required if k not in vals]
    if missing:
        sys.exit(f"ERROR: could not extract {missing} from {path} -- SDF format changed?")

    # Sanity: the registered output must be faster than the raw latch read,
    # or we have matched the modes backwards.
    if not vals["clk_to_do_reg"] < vals["clk_to_do"]:
        sys.exit("ERROR: registered clock-to-out is not faster than unregistered "
                 f"({vals['clk_to_do_reg']} vs {vals['clk_to_do']}) -- modes matched backwards?")
    return vals


SDF_TEMPLATE = '''(DELAYFILE
  (SDFVERSION "3.0")
  (DESIGN "{tile}")
  (TIMESCALE 1ns)
{cells})
'''

CELL_TEMPLATE = '''  (CELL
    (CELLTYPE "{ct}")
    (INSTANCE {ct})
    (DELAY (ABSOLUTE
      (IOPATH CLKARDCLK DOADO ({d}:{d}:{d}) ({d}:{d}:{d}))
      (IOPATH CLKARDCLK DOPADOP ({d}:{d}:{d}) ({d}:{d}:{d}))
      (IOPATH CLKBWRCLK DOBDO ({d}:{d}:{d}) ({d}:{d}:{d}))
      (IOPATH CLKBWRCLK DOPBDOP ({d}:{d}:{d}) ({d}:{d}:{d}))
    ))
    (TIMINGCHECK
      (SETUP ADDRARDADDR (posedge CLKARDCLK) ({su}:{su}:{su}))
      (HOLD  ADDRARDADDR (posedge CLKARDCLK) ({ho}:{ho}:{ho}))
      (SETUP ADDRBWRADDR (posedge CLKBWRCLK) ({su}:{su}:{su}))
      (HOLD  ADDRBWRADDR (posedge CLKBWRCLK) ({ho}:{ho}:{ho}))
    )
  )
'''


def write_db(out_dir, vals):
    os.makedirs(out_dir, exist_ok=True)
    written = []
    for tile in ("BRAM_L", "BRAM_R"):
        cells = "".join(
            CELL_TEMPLATE.format(ct=ct, d=vals["clk_to_do"],
                                 su=vals["addr_setup"], ho=vals["addr_hold"])
            for ct in ("RAMB18E1", "RAMB36E1"))
        p = os.path.join(out_dir, tile + ".sdf")
        open(p, "w").write(SDF_TEMPLATE.format(tile=tile, cells=cells))
        written.append(p)
    return written


HEADER_TEMPLATE = '''// GENERATED by tools/make_bram_timing.py -- do not edit by hand.
//
// Block RAM timing for the xc7 arch, in nanoseconds. Extracted from
// prjxray's {family} SDF, RAMB18 true-dual-port arcs, slow-corner maxima.
// See openxc7/make-bram-timing-db.sh for provenance and limits (short
// version: Artix-7 data, so pessimistic for Kintex-7; guidance, not
// sign-off).
#ifndef XC7_BRAM_TIMING_H
#define XC7_BRAM_TIMING_H

// Clock to DOUT with the optional output register DISABLED (DO_REG=0),
// which is what a plain `q <= mem[addr]` infers.
static constexpr double XC7_BRAM_CLK_TO_DO_NS = {clk_to_do};
// ... and ENABLED (DO_REG=1). This is the mode the 458MHz FMAX_BRAM
// rating in DS182 assumes.
static constexpr double XC7_BRAM_CLK_TO_DO_REG_NS = {clk_to_do_reg};
static constexpr double XC7_BRAM_ADDR_SETUP_NS = {addr_setup};
static constexpr double XC7_BRAM_ADDR_HOLD_NS = {addr_hold};

#endif
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="prjxray <family>/timings dir to extract from")
    ap.add_argument("--out-db", required=True, help="kintex7/timings dir to write")
    ap.add_argument("--vivado-sdf",
                    help="optional: SDF from Vivado write_sdf on a routed checkpoint "
                         "for this exact part. Overrides the unregistered clock->DO "
                         "arc with real measured device data instead of the artix7 proxy.")
    ap.add_argument("--out-header", required=True, help="C++ header to write")
    a = ap.parse_args()

    vals = extract(a.src, vivado_sdf=a.vivado_sdf)
    family = os.path.basename(os.path.dirname(a.src.rstrip("/")))

    print("extracted block RAM timing (ns, slow-corner max):")
    print(f"  clock->DOUT, output reg off : {vals['clk_to_do']}")
    print(f"  clock->DOUT, output reg on  : {vals['clk_to_do_reg']}")
    print(f"  address setup               : {vals['addr_setup']}")
    print(f"  address hold                : {vals['addr_hold']}")

    for p in write_db(a.out_db, vals):
        print(f"  wrote {p}")

    os.makedirs(os.path.dirname(a.out_header), exist_ok=True)
    open(a.out_header, "w").write(HEADER_TEMPLATE.format(family=family, **vals))
    print(f"  wrote {a.out_header}")

    # The other tile types the two families share -- LUT, carry, DSP, IO.
    # Without these the fabric side falls back to nextpnr's 200ps-per-LUT
    # placeholders.
    import shutil
    n = 0
    for f in sorted(os.listdir(a.src)):
        if not f.endswith(".sdf") or f.startswith("BRAM_"):
            continue
        stem = f[:-4].lower()
        db_root = os.path.dirname(a.out_db.rstrip("/"))
        if any(os.path.isfile(os.path.join(db_root, p))
               for p in (f"segbits_{stem}.db", f"segbits_{stem}.block_ram.db")):
            shutil.copy(os.path.join(a.src, f), os.path.join(a.out_db, f))
            n += 1
    print(f"  copied {n} other shared tile SDFs ({family} -> kintex7)")


if __name__ == "__main__":
    main()
