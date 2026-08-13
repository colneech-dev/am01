#!/usr/bin/env python3
"""
Shared-BRAM S-boxes WITH the clk_h/clk_2x boundary registered.

WHY THIS EXISTS ON TOP OF mux2_transform.py
-------------------------------------------
The plain mux2 transform halves block RAM (420 -> 210 per hash instance)
and is bit-exact, but place-and-route gives clk_2x = 103.72 MHz against
the ~170 MHz needed, so it only buys 1.22x.

The reason is structural. In encrypt.v a full_round is two pipeline
stages, and the S-box register is one of them:

    state[i] --pbox0 (pure wiring)--> S-box address
      [S-box REGISTER]
    S-box out --pbox1--> rotations --> round_key --> next[i]
      [state REGISTER]

Interleaving means one of the two slots must be serviced off-edge, so
either its address is sampled half a clk_h early or its result appears
half a clk_h late. Either way a path that needs a full clk_h (~9.6ns) is
squeezed into one clk_2x window (5.888ns). No amount of routing effort
fixes that; it is inherent to multiplexing.

This transform registers BOTH sides on clk_h, so every clk_2x-domain path
is register -> mux -> BRAM or BRAM -> register, and the long round logic
keeps a full clk_h. Cost: 2 extra clk_h cycles per S-box.

WHY EXACTLY 2, NOT 1
--------------------
encrypt_4encrypt_loop is a RECIRCULATING loop, not a feed-forward pipe:

    21 rounds x 2 stages + 1 = 43 = the depth of period[42:0]
    progress is 172 = THROUGHPUT(4) x 43, and write = progress[171]

Blocks enter every THROUGHPUT cycles and make THROUGHPUT passes, so
gcd(THROUGHPUT, loop_depth) must be 1 or passes collide:

    +1 cycle/round -> loop 64,  gcd(4,64)=4   BROKEN
    +2 cycle/round -> loop 85,  gcd(4,85)=1   OK
    +3 cycle/round -> loop 106, gcd(4,106)=2  BROKEN

So +2 is both what the boundary registers need and the only depth in
range that keeps the loop schedule sound.

EVERYTHING THAT HAS TO MOVE WITH IT
-----------------------------------
  * large S-boxes: address regs + output re-align regs (+2 clk_h)
  * small S-boxes: +2 pipeline stages, or the round is unbalanced
  * round keys:    period[2*I] -> period[4*I]
  * period array:  [42:0] -> [84:0], recirculate from period[84]
  * progress:      [171:0] -> [339:0], write = progress[339]

Usage:
    mux2_pipelined_transform.py <in encrypt.v> <out encrypt_mux2p.v>

STATUS: FAILED ON BOTH COUNTS. Do not use. Kept for the reasoning only.

  1. SLOWER, not faster. Place-and-route of the real pipelined miner gives
     clk_2x = 88.80 MHz against the unpipelined 103.72 -- a 14% REGRESSION.
     The premise was wrong: registering the address does not buy it a full
     clk_h, because the BRAM still samples that address on clk_2x. Launch
     point moved, constraint did not. Every path INTO a time-multiplexed
     memory is capped at one clk_2x period no matter how it is registered,
     and that is inherent to multiplexing rather than fixable in RTL.

  2. NOT EQUIVALENT. sim/tb_encrypt_equiv_seq.v reports 140/140 mismatches
     with the muxed output all-X -- it never produces defined data at all.
     Structure inspects as correct (small S-boxes at 3 stages, state
     pipeline intact, data reaching next[20] at t+339 against write at
     t+340, mirroring the original's t+171/t+172), so the fault was not
     found. It was not chased further because (1) makes the design
     unusable regardless.

     Note the negative control emitted byte-identical output to the
     intended run, so that session could not have told good hardware from
     bad. A pass would have meant nothing either.

The gcd analysis below is the part worth keeping: it shows a +1-cycle
variant would have synthesised, fitted, met timing and silently hashed
wrong.

Verify with ../sim/run_encrypt_equiv_seq.v before believing any of it --
this changes pipeline depth, which is exactly the kind of change that
still synthesises and fits while computing the wrong hash.
"""
import re, sys, collections, math

ROUNDS = 21
EXTRA = 2                      # extra clk_h cycles per S-box
STAGES = 2 + EXTRA             # pipeline stages per full_round
LOOP = ROUNDS * STAGES + 1     # new recirculation depth
THROUGHPUT = 4
PROGRESS = THROUGHPUT * LOOP

MUXED_MODULE = """
// Two users of large table {idx} sharing ONE block RAM, with the
// clk_h/clk_2x boundary registered on both sides. Latency is 3 clk_h
// (was 1); see tools/mux2_pipelined_transform.py for why +2 and why the
// loop/period/progress constants move with it.
module encrypt_4sbox_large{idx}_mux2(clk, clk2x, phase,
                                     s0_a_in, s0_b_in, s0_a_out, s0_b_out,
                                     s1_a_in, s1_b_in, s1_a_out, s1_b_out);
    input clk, clk2x, phase;
    input [9:0] s0_a_in, s0_b_in, s1_a_in, s1_b_in;
    output reg [9:0] s0_a_out, s0_b_out, s1_a_out, s1_b_out;

    (* ram_style = "block" *)
    reg [9:0] mem[0:1023];

    // Capture addresses on clk_h. The path feeding them runs from the
    // previous round's state register through pbox0, and needs a full
    // clk_h -- sampling it on a clk_2x edge is what capped the
    // unregistered version at 103.72 MHz.
    reg [9:0] s0_ar, s0_br, s1_ar, s1_br;
    always @(posedge clk) begin
        s0_ar <= s0_a_in; s0_br <= s0_b_in;
        s1_ar <= s1_a_in; s1_br <= s1_b_in;
    end

    // The shared memory, interleaved on clk2x. Both source operands are
    // now registers, so this path is short by construction.
    wire [9:0] a_addr = phase ? s1_ar : s0_ar;
    wire [9:0] b_addr = phase ? s1_br : s0_br;
    reg [9:0] a_q, b_q;
    reg phase_q;
    always @(posedge clk2x) begin
        a_q     <= mem[a_addr];
        b_q     <= mem[b_addr];
        phase_q <= phase;
    end

    // Demux to per-slot holding registers, still on clk2x.
    reg [9:0] s0_ah, s0_bh, s1_ah, s1_bh;
    always @(posedge clk2x) begin
        if (!phase_q) begin s0_ah <= a_q; s0_bh <= b_q; end
        else          begin s1_ah <= a_q; s1_bh <= b_q; end
    end

    // Re-align BOTH slots to clk_h. Without this the off-edge slot
    // presents its result mid-period and the round logic downstream
    // (pbox1 -> rotations -> round_key) gets only half a clk_h.
    always @(posedge clk) begin
        s0_a_out <= s0_ah; s0_b_out <= s0_bh;
        s1_a_out <= s1_ah; s1_b_out <= s1_bh;
    end

    initial begin
{table}
    end
endmodule
"""


def die(msg):
    sys.exit("ERROR: " + msg)


def main(src_path, dst_path):
    src = open(src_path).read()

    # Sanity: this transform hardcodes constants derived from THROUGHPUT=4
    # and 21 rounds. Refuse to run on anything else.
    if "localparam THROUGHPUT = 4;" not in src:
        die("expected THROUGHPUT=4; constants here are derived from it")
    assert math.gcd(THROUGHPUT, LOOP) == 1

    # ---- 1. large S-box tables -> shared muxed modules ----
    tables = {}
    for m in re.finditer(r'module (encrypt_4sbox_large(\d+))\((.*?)\);\n(.*?)\nendmodule',
                         src, re.S):
        idx, body = int(m.group(2)), m.group(4)
        init = re.search(r'initial begin\n(.*?)\n    end', body, re.S)
        if not init:
            die(f"no initial block in encrypt_4sbox_large{idx}")
        tables[idx] = init.group(1)
    if len(tables) != 10:
        die(f"expected 10 large tables, found {len(tables)}")
    muxed = [MUXED_MODULE.format(idx=i, table=tables[i]) for i in sorted(tables)]
    print(f"  large S-boxes : {len(tables)} tables -> shared modules, +{EXTRA} clk_h each")

    # ---- 2. small S-boxes gain the SAME latency, or rounds skew ----
    # apply_sboxes runs 40 small and 20 large S-boxes in parallel into one
    # output word. If only the large ones get deeper, the round is torn.
    def small_repl(m):
        whole, width = m.group(0), m.group(1)
        old = "    always @(posedge clk) begin\n        out <= mem[in];\n    end"
        if old not in whole:
            die("small S-box register block not found")
        new_body = (f"    reg [{width}:0] q1, q2;\n"
                    "    always @(posedge clk) begin\n"
                    "        q1  <= mem[in];\n"
                    "        q2  <= q1;\n"
                    "        out <= q2;\n"
                    "    end")
        return whole.replace(old, new_body)

    src, n_small = re.subn(
        r'module encrypt_4sbox_small\d+\(clk, in, out\);\n'
        r'    input clk;\n'
        r'    input \[\d+:0\] in;\n'
        r'    output reg \[(\d+):0\] out;\n'
        r'    reg \[\d+:0\] mem\[0:\d+\];\n'
        r'    always @\(posedge clk\) begin\n        out <= mem\[in\];\n    end',
        small_repl, src)
    if n_small != 40:
        die(f"expected 40 small S-boxes, rewrote {n_small}")
    print(f"  small S-boxes : {n_small} padded by +{EXTRA} stages to stay in step")

    # ---- 3. pair the large instances inside apply_sboxes ----
    m = re.search(r'(module encrypt_4apply_sboxes\(clk, in, out\);\n)(.*?)(\nendmodule)', src, re.S)
    if not m:
        die("encrypt_4apply_sboxes not in expected form")
    head, body, tail = m.group(1), m.group(2), m.group(3)
    inst_re = re.compile(
        r'^\s*encrypt_4sbox_large(\d+) (\w+)\(clk, ([^,]+), ([^,]+), ([^,]+), ([^)]+)\);\s*$')
    by_table, kept = collections.defaultdict(list), []
    for line in body.split('\n'):
        mm = inst_re.match(line)
        if mm:
            by_table[int(mm.group(1))].append(mm.groups()[1:])
        else:
            kept.append(line)
    new_insts = []
    for idx in sorted(by_table):
        pair = by_table[idx]
        if len(pair) != 2:
            die(f"table {idx} has {len(pair)} instances, expected 2")
        (n0, a0, b0, oa0, ob0), (n1, a1, b1, oa1, ob1) = pair
        new_insts.append(
            f"    encrypt_4sbox_large{idx}_mux2 {n0}_{n1}_mux(clk, clk2x, phase,\n"
            f"        {a0}, {b0}, {oa0}, {ob0},\n"
            f"        {a1}, {b1}, {oa1}, {ob1});")
    src = (src[:m.start()]
           + head.replace("(clk, in, out)", "(clk, clk2x, phase, in, out)")
           + "    input clk2x, phase;\n" + '\n'.join(kept) + '\n'
           + '\n'.join(new_insts) + tail + src[m.end():])
    print(f"  paired        : {sum(len(v) for v in by_table.values())} instances -> {len(new_insts)} shared BRAMs")

    # ---- 4. plumb clk2x/phase down the hierarchy ----
    src = src.replace(
        "module encrypt_4full_round(clk, roundkey, in, out);\n    input clk;",
        "module encrypt_4full_round(clk, clk2x, phase, roundkey, in, out);\n    input clk, clk2x, phase;")
    src = src.replace("encrypt_4apply_sboxes sboxes(clk, mid[0], mid[1]);",
                      "encrypt_4apply_sboxes sboxes(clk, clk2x, phase, mid[0], mid[1]);")
    src = src.replace(
        "module encrypt_4encrypt_loop(clk, in, read, out, write);\n    input clk;",
        "module encrypt_4encrypt_loop(clk, clk2x, phase, in, read, out, write);\n    input clk, clk2x, phase;")
    n_fr = len(re.findall(r'encrypt_4full_round \w+\(clk,', src))
    if n_fr != ROUNDS:
        die(f"expected {ROUNDS} full_round instantiations, found {n_fr}")
    src = re.sub(r'(encrypt_4full_round \w+\()clk,', r'\1clk, clk2x, phase,', src)
    src, n = re.subn(
        r'module encrypt_4encrypt\(clk, in, read, out, write\);\n'
        r'((?:\s*localparam[^\n]*\n)*)    input clk;',
        lambda mm: ('module encrypt_4encrypt(clk, clk2x, phase, in, read, out, write);\n'
                    + mm.group(1) + '    input clk, clk2x, phase;'), src)
    if n != 1:
        die(f"encrypt_4encrypt header rewrite matched {n}")
    src = re.sub(r'(encrypt_4encrypt_loop \w+\()clk,', r'\1clk, clk2x, phase,', src)

    # ---- 5. round keys: period[2*I] -> period[STAGES*I] ----
    def key_repl(m):
        i = int(m.group(1))
        return f"encrypt_4get_round_key{i} get_key{i}(clk, period[{STAGES*i}], roundkey[{i}]);"
    src, n_keys = re.subn(r'encrypt_4get_round_key(\d+) get_key\d+\(clk, period\[\d+\], roundkey\[\d+\]\);',
                          key_repl, src)
    if n_keys != ROUNDS:
        die(f"expected {ROUNDS} round-key instantiations, rewrote {n_keys}")
    print(f"  round keys    : re-indexed to period[{STAGES}*I], max period[{STAGES*(ROUNDS-1)}]")

    # ---- 6. grow the period recirculation 43 -> LOOP ----
    if f"reg [1:0] period[{LOOP-1}:0];" in src:
        die("period already resized -- transform applied twice?")
    src, n = re.subn(r'reg \[1:0\] period\[42:0\];', f'reg [1:0] period[{LOOP-1}:0];', src)
    if n != 1:
        die("period declaration not found")
    old_chain = '\n'.join(f"    always @(posedge clk) period[{i}] <= period[{i-1}];"
                          for i in range(1, 43))
    new_chain = '\n'.join(f"    always @(posedge clk) period[{i}] <= period[{i-1}];"
                          for i in range(1, LOOP))
    if old_chain not in src:
        die("period shift chain not in expected form")
    src = src.replace(old_chain, new_chain)
    src, n = re.subn(r'period\[0\] <= period\[42\]\+1;', f'period[0] <= period[{LOOP-1}]+1;', src)
    if n != 1:
        die("period recirculation not found")
    print(f"  period        : depth 43 -> {LOOP} (gcd({THROUGHPUT},{LOOP})={math.gcd(THROUGHPUT,LOOP)})")

    # ---- 7. grow progress 172 -> PROGRESS ----
    src, n = re.subn(r'reg \[171:0\] progress;', f'reg [{PROGRESS-1}:0] progress;', src)
    if n != 1:
        die("progress declaration not found")
    src, n = re.subn(r"initial progress = 172'h0;", f"initial progress = {PROGRESS}'h0;", src)
    if n != 1:
        die("progress initial not found")
    old_chain = '\n'.join(f"    always @(posedge clk) progress[{i}] <= progress[{i-1}];"
                          for i in range(1, 172))
    new_chain = '\n'.join(f"    always @(posedge clk) progress[{i}] <= progress[{i-1}];"
                          for i in range(1, PROGRESS))
    if old_chain not in src:
        die("progress shift chain not in expected form")
    src = src.replace(old_chain, new_chain)
    src, n = re.subn(r'assign write = progress\[171\];', f'assign write = progress[{PROGRESS-1}];', src)
    if n != 1:
        die("write assignment not found")
    print(f"  progress      : depth 172 -> {PROGRESS}, write = progress[{PROGRESS-1}]")

    # ---- 8. every module using clk2x must declare it ----
    for mod in ("encrypt_4apply_sboxes", "encrypt_4full_round",
                "encrypt_4encrypt_loop", "encrypt_4encrypt"):
        b = re.search(r'module ' + mod + r'\(.*?\nendmodule', src, re.S)
        if not b:
            die(f"{mod} missing after transform")
        t = b.group(0)
        if "clk2x" in t and "input clk, clk2x, phase;" not in t and "input clk2x, phase;" not in t:
            die(f"{mod} uses clk2x/phase without declaring them")

    src += "\n" + "\n".join(muxed)
    open(dst_path, "w").write(src)
    print(f"  wrote {dst_path}")
    print("\n  NOT verified by this script. Pipeline depth changed -- run")
    print("  ../sim/run_encrypt_equiv.sh before trusting it.")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
