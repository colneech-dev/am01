// Copyright (C) 2019 MentalCollatz
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

#include "odocrypt.h"

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <cstring>

class OdoVerilog: public OdoCrypt
{
public:
    OdoVerilog(uint32_t seed): OdoCrypt(seed), m_seed(seed) {}
    void Generate(int throughput, const char* prefix = NULL, FILE* f = stdout) const;
private:
    // Kept so Generate() can stamp the output with the epoch it belongs to.
    // Without that, a stale encrypt.v is indistinguishable from a fresh one
    // by inspection -- the only way to tell is to regenerate and diff.
    uint32_t m_seed;
};

#define NIBBLES(x) x, (1 + ((x)-1) / 4)

// Optional extra output-register stage on every S-box read.
//
// Set by --bram-out-reg. With it, a block-RAM read infers DO_REG=1 (clock-to-DO
// ~0.88 ns instead of ~2.45 ns, per the Vivado-extracted SDF), at the cost of
// one extra pipeline cycle per round. Applies to small AND large S-boxes: they
// share the apply_sboxes block, so registering only one kind would
// desynchronise every round.
static bool g_bram_out_reg = false;
// Clock cycles per round: one for the S-box read, one for the state register,
// plus one more when the output register is enabled.
static int RoundCycles() { return g_bram_out_reg ? 3 : 2; }

// Number of the 10 large-S-box module TYPES (sbox_large0..9) to infer as
// distributed RAM (SLICEM LUTRAM) instead of block RAM. Set by --lutram=N.
//
// Each of the 10 types is instantiated once per unrolled round, so N of 10
// converts almost exactly N/10 of total large-S-box BRAM demand into LUT
// fabric -- a direct lever on BRAM occupancy for wide/multi-miner configs
// where BRAM, not LUTs, is the binding resource (see RESULTS.md, AM01
// hashrate scaling options). Cost model (per am01-hashrate-scaling-options
// memory): ~420 LUTs per converted instance (a 1024x10 dual-port ROM as
// logic, ~21 LUTs/bit x 10 bits x 2 ports).
static int g_lutram_count = 0;

// Which period[] tap feeds round i's key.
//
// full_round applies the key COMBINATIONALLY after the sboxes:
//     pbox0 -> apply_sboxes (clocked) -> pbox1 -> rotations -> apply_round_key
// so the key must be valid when the sbox output emerges, and get_round_key is
// itself clocked, so a tap read at X yields a key at X+1:
//
//     block reaches state[i] at   t0 + RoundCycles*i
//     sbox output emerges at      + sbox_latency
//     tap period[T] gives key at  t0 + T + 1
//     => T = RoundCycles*i + sbox_latency - 1
//
// RoundCycles = sbox_latency + 1 (the sbox, then the state register), so this
// is RoundCycles*(i+1) - 2: exactly 2*i for a single-register sbox, and 3*i+1
// once --bram-out-reg makes the sbox two deep.
//
// Emitting RoundCycles()*i here -- scaling for the round but not for the deeper
// sbox -- made the key arrive ONE CYCLE EARLY and produced a core that ran at
// full speed and computed wrong results. Caught by tb_sched_equiv.v +blocks=1.
static int RoundKeyTap(int i) { return RoundCycles() * (i + 1) - 2; }

template<typename T, size_t sz1, size_t sz2>
void GenerateSboxes(const T (&sbox)[sz1][sz2], bool dual_port, const char* prefix, const char* suffix, FILE* f)
{
    int width = 0;
    while ((1 << width) < sz2)
        width++;
    assert((1 << width) == sz2);
    for (int i = 0; i < sz1; i++)
    {
        if (!dual_port)
        {
            fprintf(f, "module %ssbox_%s%d(clk, in, out);\n", prefix, suffix, i);
            fprintf(f, "    input clk;\n");
            fprintf(f, "    input [%d:0] in;\n", width-1);
            fprintf(f, "    output reg [%d:0] out;\n", width-1);
            fprintf(f, "    reg [%d:0] mem[0:%zd];\n", width-1, sz2-1);
            if (g_bram_out_reg)
            {
                fprintf(f, "    reg [%d:0] q1;\n", width-1);
                fprintf(f, "    always @(posedge clk) begin\n");
                fprintf(f, "        q1 <= mem[in];\n");
                fprintf(f, "        out <= q1;\n");
                fprintf(f, "    end\n");
            }
            else
            {
                fprintf(f, "    always @(posedge clk) begin\n");
                fprintf(f, "        out <= mem[in];\n");
                fprintf(f, "    end\n");
            }
        }
        else
        {
            fprintf(f, "module %ssbox_%s%d(clk, a_in, b_in, a_out, b_out);\n", prefix, suffix, i);
            fprintf(f, "    input clk;\n");
            fprintf(f, "    input [%d:0] a_in;\n", width-1);
            fprintf(f, "    output reg [%d:0] a_out;\n", width-1);
            fprintf(f, "    input [%d:0] b_in;\n", width-1);
            fprintf(f, "    output reg [%d:0] b_out;\n", width-1);
            // Explicit ram_style forces Vivado's choice instead of letting its
            // own heuristic decide. Measured necessary: without it, Vivado
            // synthesizes correctly up to ~220 of these per instance, then
            // silently doubles to 2 RAMB18E1 each past ~240 -- a total-design
            // memory-object-count threshold, not a per-module inference
            // issue (confirmed: reproduces even with two structurally
            // distinct, differently-named module trees, so it isn't about
            // Vivado conflating duplicate instances either). With this
            // attribute the correct count holds even past that threshold.
            // yosys already infers this correctly regardless; unaffected.
            //
            // --lutram=N converts the first N of these sz1 module TYPES
            // (i < g_lutram_count) to distributed RAM instead. Only meaningful
            // when dual_port (the large S-boxes, the only ones this cost model
            // was measured against); small S-boxes are already tiny enough
            // that yosys/Vivado map them to LUTs on their own.
            fprintf(f, "    (* ram_style = \"%s\" *) reg [%d:0] mem[0:%zd];\n",
                    (dual_port && i < g_lutram_count) ? "distributed" : "block",
                    width-1, sz2-1);
            // Separate always blocks per port, each with its own read of the
            // shared `mem` array -- Vivado's dual-port BRAM inference is
            // pattern-sensitive and doesn't reliably collapse two reads in
            // one always block into a single true-dual-port RAMB18 (it was
            // observed synthesizing 2 BRAMs per instance here instead of 1,
            // doubling the design's block RAM usage). yosys's memory_bram
            // pass recognized the original single-always-block form fine;
            // this two-block form is the documented-safer template for both
            // (see AMD/Xilinx UG901's memory inference coding guidelines).
            if (g_bram_out_reg)
            {
                // Two registers in series on each port is the template that
                // infers RAMB18 with DO_REG=1 -- the second register maps to
                // the block RAM's own optional output register rather than to
                // fabric flops.
                fprintf(f, "    reg [%d:0] a_q1;\n", width-1);
                fprintf(f, "    reg [%d:0] b_q1;\n", width-1);
                fprintf(f, "    always @(posedge clk) begin\n");
                fprintf(f, "        a_q1 <= mem[a_in];\n");
                fprintf(f, "        a_out <= a_q1;\n");
                fprintf(f, "    end\n");
                fprintf(f, "    always @(posedge clk) begin\n");
                fprintf(f, "        b_q1 <= mem[b_in];\n");
                fprintf(f, "        b_out <= b_q1;\n");
                fprintf(f, "    end\n");
            }
            else
            {
                fprintf(f, "    always @(posedge clk) begin\n");
                fprintf(f, "        a_out <= mem[a_in];\n");
                fprintf(f, "    end\n");
                fprintf(f, "    always @(posedge clk) begin\n");
                fprintf(f, "        b_out <= mem[b_in];\n");
                fprintf(f, "    end\n");
            }
        }
        fprintf(f, "    initial begin\n");
        for (int j = 0; j < sz2; j++)
        {
            fprintf(f, "        mem[%d] = %d'h%0*x;\n", j, NIBBLES(width), sbox[i][j]);
        }
        fprintf(f, "    end\n");
        fprintf(f, "endmodule\n\n");
    }
}

int gcd(int a, int b)
{
    return b == 0 ? a : gcd(b, a%b);
}

void OdoVerilog::Generate(int throughput, const char* prefix, FILE* f) const
{
    if (!prefix) prefix = "";

    // Provenance header. OdoCrypt mutates every 10 days, so this file is only
    // correct for one epoch; stamping the seed makes a stale copy obvious
    // instead of requiring a regenerate-and-diff to find out.
    {
        const uint32_t interval = 864000;   /* ODO_EPOCH_INTERVAL_MAINNET */
        time_t from = (time_t)m_seed;
        time_t to   = (time_t)(m_seed + interval);
        char fbuf[32] = "?", tbuf[32] = "?";
        struct tm tmv;
        if (gmtime_r(&from, &tmv)) strftime(fbuf, sizeof(fbuf), "%Y-%m-%d %H:%M UTC", &tmv);
        if (gmtime_r(&to,   &tmv)) strftime(tbuf, sizeof(tbuf), "%Y-%m-%d %H:%M UTC", &tmv);

        fprintf(f, "// AUTOGENERATED by tools/odo_gen -- do not edit.\n");
        fprintf(f, "//\n");
        fprintf(f, "// OdoCrypt epoch seed: %u\n", (unsigned)m_seed);
        fprintf(f, "// Valid from:          %s\n", fbuf);
        fprintf(f, "// Stale after:         %s\n", tbuf);
        fprintf(f, "// Throughput:          %d    Prefix: %s\n", throughput,
                prefix[0] ? prefix : "(none)");
        // MACHINE-READABLE, and the reason it exists: nothing recorded which
        // core this file is. The regenerate command below was stamped WITHOUT
        // --bram-out-reg no matter which mode produced the file, so following
        // it after a --bram-out-reg build silently swapped a 3-cycle-per-round
        // core for a 2-cycle one. Different round-key timing, different
        // place-and-route, and nothing to notice because the command in the
        // header still looked correct.
        //
        // tools/check-epoch.sh reads this line back and echoes whatever it
        // finds, so the instruction cannot drift from the artefact again.
        fprintf(f, "// odo_gen flags:       %s\n",
                g_bram_out_reg ? "--bram-out-reg" : "(none)");
        fprintf(f, "// Round cycles:        %d  %s\n", RoundCycles(),
                g_bram_out_reg ? "(sbox read, output register, state register)"
                               : "(sbox read, state register)");
        fprintf(f, "//\n");
        fprintf(f, "// OdoCrypt mutates every 10 days (ntime - ntime %% %u). A bitstream\n", interval);
        fprintf(f, "// built from this file produces valid shares only while the chain's job\n");
        fprintf(f, "// epoch equals the seed above; past that it mines rejects. Regenerate:\n");
        fprintf(f, "//   cd tools/odo_gen && make odo_gen\n");
        fprintf(f, "//   ./odo_gen <seed> %d %s%s > ../../hdl/odocrypt/encrypt.v\n",
                throughput, prefix[0] ? prefix : "encrypt_4",
                g_bram_out_reg ? " --bram-out-reg" : "");
        fprintf(f, "// and update ODO_SEED in\n");
        fprintf(f, "// hardware/qmtech-kintex7/hdl/odocrypt_gpio_wrapper.v to match.\n");
        fprintf(f, "// tools/check-epoch.sh verifies the two agree.\n");
        fprintf(f, "//\n");
        fprintf(f, "// The flag above is NOT optional -- see \"odo_gen flags\" above.\n");
        fprintf(f, "// Changing it produces a DIFFERENT core: the round-key tap moves,\n");
        fprintf(f, "// and timing results from the other mode do not carry over.\n");
        fprintf(f, "\n");
    }

    int unrolling = (ROUNDS-1) / throughput + 1;
    // Start at 1, not 0. extra_delay adds REGISTERED pass-through stages
    // (see the `assign next[i+unrolling] = state[i+unrolling]` loop below),
    // and those stages sit in the recirculation path from the last round back
    // to state[0]. With extra_delay=0 that feedback crosses the entire design
    // combinationally; the rounds are spread across the die by the BRAM
    // floorplan, so it becomes the critical path.
    //
    // Measured, six seeds each, identical apart from this: extra_delay=1 gives
    // 104-120 MHz and a critical path ending mid-pipeline at next[10..16];
    // extra_delay=0 gives 81-85 MHz and a critical path ending at state[0] on
    // EVERY seed. A 31 MHz median difference with no distribution overlap.
    //
    // The search previously began at 0 and took the first coprime value, so
    // whether a relay existed was arithmetic luck -- throughput 4 with 2
    // cycles/round happened to be bumped to 1, while 3 cycles/round accepted 0.
    //
    // Costs one pipeline stage of latency, which does not affect hashrate:
    // THROUGHPUT is clocks-per-hash and the core self-reports `write`.
    int extra_delay = 1;
    while (gcd(throughput, RoundCycles()*unrolling+extra_delay) != 1)
        extra_delay++;
    int periods = (ROUNDS-1) / unrolling + 1;
    int latency = RoundCycles()*ROUNDS + (periods-1) * extra_delay + 1;
    int period_bits = 1;
    while ((1 << period_bits) < periods)
        period_bits++;

    // pre-mix
    fprintf(f, "module %spre_mix(in, out);\n", prefix);
    fprintf(f, "    input [%d:0] in;\n", DIGEST_BITS-1);
    fprintf(f, "    output [%d:0] out;\n", DIGEST_BITS-1);
    fprintf(f, "    wire [%d:0] total;\n", WORD_BITS-1);
    fprintf(f, "    assign total = 0");
    for (int i = 0; i < STATE_SIZE; i++)
        fprintf(f, " ^ in[%d:%d]", WORD_BITS*(i+1)-1, WORD_BITS*i);
    fprintf(f, ";\n");
    for (int i = 0; i < STATE_SIZE; i++)
        fprintf(f, "    assign out[%d:%d] = in[%d:%d] ^ total ^ (total >> 32);\n",
                WORD_BITS*(i+1)-1, WORD_BITS*i, WORD_BITS*(i+1)-1, WORD_BITS*i);
    fprintf(f, "endmodule\n\n");

    // s-box
    GenerateSboxes(Sbox1, false, prefix, "small", f);
    GenerateSboxes(Sbox2, true, prefix, "large", f);
    {
        fprintf(f, "module %sapply_sboxes(clk, in, out);\n", prefix);
        fprintf(f, "    input clk;\n");
        fprintf(f, "    input [%d:0] in;\n", DIGEST_BITS-1);
        fprintf(f, "    output [%d:0] out;\n", DIGEST_BITS-1);
        int smallSboxIndex = 0;
        int pos = 0;
        int sboxId = 0;
        for (int i = 0; i < STATE_SIZE; i++)
        {
            int largeSboxIndex = i;
            int pairPos, pairNext;
            for (int j = 0; j < SMALL_SBOX_COUNT / STATE_SIZE; j++)
            {
                int next = pos + SMALL_SBOX_WIDTH;
                fprintf(f, "    %ssbox_small%d sbox%dinst(clk, in[%d:%d], out[%d:%d]);\n",
                        prefix, smallSboxIndex, sboxId++, next-1, pos, next-1, pos);
                pos = next;
                next = pos + LARGE_SBOX_WIDTH;
                if (j&1)
                {
                    fprintf(f, "    %ssbox_large%d sbox%dinst(clk, in[%d:%d], in[%d:%d], out[%d:%d], out[%d:%d]);\n",
                            prefix, largeSboxIndex, sboxId++,
                            pairNext-1, pairPos, next-1, pos,
                            pairNext-1, pairPos, next-1, pos);
                }
                else
                {
                    pairPos = pos;
                    pairNext = next;
                }
                pos = next;
                smallSboxIndex++;
            }
        }
        fprintf(f, "endmodule\n\n");
    }

    // p-box
    for (int i = 0; i < 2; i++)
    {
        fprintf(f, "module %sapply_pbox%d(in, out);\n", prefix, i);
        fprintf(f, "    input [%d:0] in;\n", DIGEST_BITS-1);
        fprintf(f, "    output [%d:0] out;\n", DIGEST_BITS-1);
        const Pbox& pbox = Permutation[i];
        int perm[DIGEST_BITS];
        for (int j = 0; j < DIGEST_BITS; j++)
        {
            int word = j / WORD_BITS;
            int bit = j % WORD_BITS;
            for (int r = 0; r < PBOX_SUBROUNDS; r++)
            {
                // masked swap
                if ((pbox.mask[r][word/2] >> bit) & 1)
                    word ^= 1;
                if (r < PBOX_SUBROUNDS-1)
                {
                    // word shuffle
                    word = word * PBOX_M % STATE_SIZE;
                    // rotation
                    if (!(word & 1))
                        bit = (bit + pbox.rotation[r][word/2]) % WORD_BITS;
                }
            }
            fprintf(f, "    assign out[%d] = in[%d];\n", word*WORD_BITS + bit, j);
        }
        fprintf(f, "endmodule\n\n");
    }

    // rotations
    fprintf(f, "module %srotation_helper(in, out);\n", prefix);
    fprintf(f, "    input [%d:0] in;\n", WORD_BITS-1);
    fprintf(f, "    output [%d:0] out;\n", WORD_BITS-1);
    fprintf(f, "    assign out = ");
    for (int i = 0; i < ROTATION_COUNT; i++)
    {
        if (i != 0)
            fprintf(f, " ^ ");
        fprintf(f, "{in[%d:%d], in[%d:%d]}", WORD_BITS-1-Rotations[i], 0, WORD_BITS-1, WORD_BITS-Rotations[i]);
    }
    fprintf(f, ";\n");
    fprintf(f, "endmodule\n\n");
    fprintf(f, "module %sapply_rotations(in, out);\n", prefix);
    fprintf(f, "    input [%d:0] in;\n", DIGEST_BITS-1);
    fprintf(f, "    output [%d:0] out;\n", DIGEST_BITS-1);
    fprintf(f, "    wire [%d:0] rot;\n", DIGEST_BITS-1);
    for (int i = 0; i < STATE_SIZE; i++)
    {
        fprintf(f, "    %srotation_helper rot%dinst(in[%d:%d], rot[%d:%d]);\n",
                prefix, i, (i+1)*WORD_BITS-1, i*WORD_BITS, (i+1)*WORD_BITS-1, i*WORD_BITS);
    }
    fprintf(f, "    assign out = rot ^ {in[%d:%d], in[%d:%d]};\n",
            WORD_BITS-1, 0, DIGEST_BITS-1, WORD_BITS);
    fprintf(f, "endmodule\n\n");

    // round key
    fprintf(f, "module %sapply_round_key(key, in, out);\n", prefix);
    fprintf(f, "    input [%d:0] key;\n", STATE_SIZE-1);
    fprintf(f, "    input [%d:0] in;\n", DIGEST_BITS-1);
    fprintf(f, "    output [%d:0] out;\n", DIGEST_BITS-1);
    for (int i = 0; i < STATE_SIZE; i++)
    {
        int lo = WORD_BITS*i;
        int hi = WORD_BITS*(i+1)-1;
        fprintf(f, "    assign out[%d] = in[%d] ^ key[%d];\n", lo, lo, i);
        fprintf(f, "    assign out[%d:%d] = in[%d:%d];\n", hi, lo+1, hi, lo+1);
    }
    fprintf(f, "endmodule\n\n");

    // full round
    fprintf(f, "module %sfull_round(clk, roundkey, in, out);\n", prefix);
    fprintf(f, "    input clk;\n");
    fprintf(f, "    input [%d:0] roundkey;\n", STATE_SIZE-1);
    fprintf(f, "    input [%d:0] in;\n", DIGEST_BITS-1);
    fprintf(f, "    output [%d:0] out;\n", DIGEST_BITS-1);
    fprintf(f, "    wire [%d:0] mid[0:3];\n", DIGEST_BITS-1);
    fprintf(f, "    %sapply_pbox0 pbox0inst(in, mid[0]);\n", prefix);
    fprintf(f, "    %sapply_sboxes sboxes(clk, mid[0], mid[1]);\n", prefix);
    fprintf(f, "    %sapply_pbox1 pbox1inst(mid[1], mid[2]);\n", prefix);
    fprintf(f, "    %sapply_rotations rotations(mid[2], mid[3]);\n", prefix);
    fprintf(f, "    %sapply_round_key keys(roundkey, mid[3], out);\n", prefix);
    fprintf(f, "endmodule\n\n");

    // get round key
    if (throughput != 1)
    {
        for (int i = 0; i < unrolling; i++)
        {
            fprintf(f, "module %sget_round_key%d(clk, period, key);\n", prefix, i);
            fprintf(f, "    input clk;\n");
            fprintf(f, "    input [%d:0] period;\n", period_bits-1);
            fprintf(f, "    output [%d:0] key;\n", STATE_SIZE-1);
            fprintf(f, "    reg [%d:0] key;\n", STATE_SIZE-1);
            fprintf(f, "    always @(posedge clk) begin\n");
            fprintf(f, "    case (period)\n");
            for (int j = 0, r = i; r < ROUNDS; j++, r += unrolling)
            {
                fprintf(f, "        %d'h%0*x: key <= %d'h%0*x;\n",
                    NIBBLES(period_bits), j,
                    NIBBLES(STATE_SIZE), RoundKey[r]);
            }
            fprintf(f, "    endcase\n");
            fprintf(f, "    end\n");
            fprintf(f, "endmodule\n\n");
        }
    }

    // encrypt loop
    fprintf(f, "module %sencrypt_loop(clk, in, read, out, write);\n", prefix);
    fprintf(f, "    input clk;\n");
    fprintf(f, "    input [%d:0] in;\n", DIGEST_BITS-1);
    fprintf(f, "    input read;\n");
    fprintf(f, "    output reg [%d:0] out;\n", DIGEST_BITS-1);
    fprintf(f, "    output write;\n");
    fprintf(f, "    reg [%d:0] state[%d:0];\n", DIGEST_BITS-1, unrolling+extra_delay-1);
    fprintf(f, "    wire [%d:0] next[%d:0];\n", DIGEST_BITS-1, unrolling+extra_delay-1);
    for (int i = 1; i < unrolling+extra_delay; i++)
        fprintf(f, "    always @(posedge clk) state[%d] <= next[%d];\n", i, i-1);
    for (int i = 0; i < extra_delay; i++)
        fprintf(f, "    assign next[%d] = state[%d];\n", i+unrolling, i+unrolling);
    if (throughput != 1)
    {
        fprintf(f, "    wire [%d:0] roundkey[%d:0];\n", STATE_SIZE-1, unrolling-1);
        fprintf(f, "    reg [%d:0] period[%d:0];\n", period_bits-1, RoundCycles()*unrolling+extra_delay-1);
        for (int i = 1; i < RoundCycles()*unrolling+extra_delay; i++)
            fprintf(f, "    always @(posedge clk) period[%d] <= period[%d];\n", i, i-1);
        for (int i = 0; i < unrolling; i++)
        {
            fprintf(f, "    %sget_round_key%d get_key%d(clk, period[%d], roundkey[%d]);\n", prefix, i, i, RoundKeyTap(i), i);
            fprintf(f, "    %sfull_round round%d(clk, roundkey[%d], state[%d], next[%d]);\n", prefix, i, i, i, i);
        }
        fprintf(f, "    always @(posedge clk) begin\n");
        fprintf(f, "        if (read)\n");
        fprintf(f, "        begin\n");
        fprintf(f, "            period[0] <= 0;\n");
        fprintf(f, "            state[0] <= in;\n");
        fprintf(f, "        end\n");
        fprintf(f, "        else\n");
        fprintf(f, "        begin\n");
        fprintf(f, "            period[0] <= period[%d]+1;\n", RoundCycles()*unrolling+extra_delay-1);
        fprintf(f, "            state[0] <= next[%d];\n", unrolling+extra_delay-1);
        fprintf(f, "        end\n");
        fprintf(f, "        out <= next[%d];\n", (ROUNDS-1) % unrolling);
        fprintf(f, "    end\n");
    }
    else
    {
        for (int i = 0; i < unrolling; i++)
        {
            fprintf(f, "    %sfull_round round%d(clk, %d'h%0*x, state[%d], next[%d]);\n",
                    prefix, i, NIBBLES(STATE_SIZE), RoundKey[i], i, i);
        }
        fprintf(f, "    always @(posedge clk) begin\n");
        fprintf(f, "        state[0] <= in;\n");
        fprintf(f, "        out <= next[%d];\n", ROUNDS-1);
        fprintf(f, "    end\n");
    }
    fprintf(f, "    reg [%d:0] progress;\n", latency-1);
    fprintf(f, "    initial progress = %d'h0;\n", latency);
    fprintf(f, "    always @(posedge clk) progress[0] <= read;\n");
    for (int i = 1; i < latency; i++)
        fprintf(f, "    always @(posedge clk) progress[%d] <= progress[%d];\n", i, i-1);
    fprintf(f, "    assign write = progress[%d];\n", latency-1);
    fprintf(f, "endmodule\n\n");

    // encrypt
    fprintf(f, "module %sencrypt(clk, in, read, out, write);\n", prefix);
    fprintf(f, "    localparam THROUGHPUT = %d;\n", throughput);
    fprintf(f, "    input clk;\n");
    fprintf(f, "    input [%d:0] in;\n", DIGEST_BITS-1);
    fprintf(f, "    input read;\n");
    fprintf(f, "    output [%d:0] out;\n", DIGEST_BITS-1);
    fprintf(f, "    output write;\n");
    fprintf(f, "    reg [1:0] progress;\n");
    fprintf(f, "    initial progress = 2'h0;\n");
    fprintf(f, "    reg [639:0] state[1:0];\n");
    fprintf(f, "    wire [639:0] next;\n");
    fprintf(f, "    %spre_mix premixer(state[0], next);\n", prefix);
    fprintf(f, "    %sencrypt_loop crypter(clk, state[1], progress[1], out, write);\n", prefix);
    fprintf(f, "    always @(posedge clk) begin\n");
    fprintf(f, "        progress[0] <= read;\n");
    fprintf(f, "        progress[1] <= progress[0];\n");
    fprintf(f, "        state[0] <= in;\n");
    fprintf(f, "        state[1] <= next;\n");
    fprintf(f, "    end\n");
    fprintf(f, "endmodule\n");
}

int usage(const char* arg0, const char* message)
{
    fprintf(stderr, "%s", message);
    fprintf(stderr, "Usage: %s <seed> <throughput> [prefix]\n", arg0);
    return 1;
}

int main(int argc, char* argv[])
{
    uint32_t key = 0;
    uint32_t throughput = 0;
    const char* prefix = NULL;
    // --bram-out-reg and --lutram=N may appear anywhere; strip them before
    // positional parsing.
    for (int i = 1; i < argc; i++)
    {
        if (strcmp(argv[i], "--bram-out-reg") == 0)
        {
            g_bram_out_reg = true;
            for (int j = i; j < argc - 1; j++)
                argv[j] = argv[j+1];
            argc--;
            i--;
        }
        else if (strncmp(argv[i], "--lutram=", 9) == 0)
        {
            g_lutram_count = atoi(argv[i] + 9);
            if (g_lutram_count < 0 || g_lutram_count > 10)
                return usage(argv[0], "--lutram=N must be 0..10 (10 large S-box module types exist)");
            for (int j = i; j < argc - 1; j++)
                argv[j] = argv[j+1];
            argc--;
            i--;
        }
    }
    if (argc < 3 || argc > 4)
        return usage(argv[0], "Incorrect number of agruments");
    key = strtoul(argv[1], NULL, 0);
    throughput = strtoul(argv[2], NULL, 0);
    if (throughput == 0)
        return usage(argv[0], "Throughput cannot be 0");
    if (argc == 4)
        prefix = argv[3];
    OdoVerilog(key).Generate(throughput, prefix);
}
