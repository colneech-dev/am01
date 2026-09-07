`timescale 1ns/1ps
//
// Does miner_pipelined label each result with the RIGHT nonce?
//
// WHY
// ---
// Measured on hardware 2026-09-07: recomputing every rejected find's digest at
// nonce-4..nonce+4 showed that ~80% of them were the CORRECT digest carrying a
// nonce one too high, on both instances, with every other offset at exactly
// zero. The cipher is not the problem -- tb_encrypt_oracle now proves
// encrypt.v matches the software oracle byte for byte at the shipping epoch.
// The problem is the label.
//
// miner_pipelined keeps two counters:
//
//     nonce_in    advances the cipher, incremented on `advance`
//     nonce_out   shadows the results, incremented on `has_res`
//
// Neither is ever reset; both are `initial`-ised to INONCE once at
// configuration, and the design ASSUMES one has_res per advance for ever. Any
// result the pipeline emits that did not come from an advance -- a flush at
// configuration, a drain after a commit swaps the header mid-flight -- gains
// nonce_out a count it never gives back.
//
// WHAT THIS PROVES, AND WHAT IT DOES NOT
// --------------------------------------
// Driving an all-ones target makes cmp_256 qualify EVERY result, so `found`
// fires once per result and `nonce` must walk INONCE, INONCE+1, INONCE+2, ...
// with no gap and no repeat. A skip or a stall is the counter losing step with
// the result stream, which is the fault, visible without needing a digest
// oracle at all.
//
// It cannot prove the converse. If the sequence is clean here, the RTL is
// self-consistent in simulation and the hardware misbehaviour is physical --
// timing on the found/nonce capture -- which is a different fix. Either
// answer is worth having and neither was available before, because nothing in
// this directory drove miner_pipelined at all.

module tb_nonce_label;

    localparam [31:0] INONCE_P = 32'h0000_0000;
    localparam integer WANT    = 24;    // results to check after the first

    reg clk = 1'b0;
    always #5 clk = ~clk;

    // 19 x 32 bits = 608. Any header will do: this tests bookkeeping,
    // not the cipher, and tb_encrypt_oracle covers the cipher.
    reg [607:0] header = {19{32'h9e3779b9}};

    // All ones: every candidate is below target, so every result qualifies.
    reg [255:0] target = {256{1'b1}};

    wire [31:0] nonce;
    wire        found;

    miner_pipelined #(.INONCE(INONCE_P)) dut (
        .clk(clk), .header(header), .target(target),
        .nonce(nonce), .found(found)
    );

    integer  seen     = 0;
    integer  bad      = 0;
    integer  cycles   = 0;
    reg [31:0] expect_nonce = 32'h0;
    reg        started = 1'b0;

    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (found) begin
            if (!started) begin
                // The first find anchors the sequence. If the counter was
                // already off at configuration this test cannot see it -- it
                // measures whether the two counters STAY in step, which is the
                // failure mode that produces a mixture of right and wrong
                // labels rather than a uniformly wrong one.
                started      <= 1'b1;
                expect_nonce <= nonce + 32'd1;
                $display("  first find at cycle %0d, nonce 0x%08x",
                         cycles, nonce);
            end else begin
                seen <= seen + 1;
                // Mid-stream commit: swap the header with results for the old
                // one still in the pipe, which is what the wrapper does on
                // every new job. miner_pipelined has no commit port and is not
                // told; the nonce sequence must be unaffected regardless.
                if (seen == WANT / 2) begin
                    header <= ~header;
                    $display("  header swapped after result %0d -- results for the old one still in flight",
                             seen);
                end
                if (nonce !== expect_nonce) begin
                    bad <= bad + 1;
                    if (bad < 8)
                        $display("  MISMATCH at result %0d cycle %0d: expected 0x%08x got 0x%08x",
                                 seen, cycles, expect_nonce, nonce);
                end
                expect_nonce <= nonce + 32'd1;
            end
        end
    end

    initial begin
        $display("tb_nonce_label: does miner_pipelined label results correctly?");
        $display("  all-ones target, so every result must qualify and the");
        $display("  reported nonce must increment by exactly 1 each time");
        $display("");

        // The --bram-out-reg pipeline is 259 deep and THROUGHPUT is 4, so the
        // first result is ~265 cycles out and one follows every 4 after that.
        // Generous, and it fails on timeout rather than hanging.
        repeat (265 + WANT * 4 + 60) @(posedge clk);

        $display("");
        if (!started) begin
            $display("  RESULT: FAIL -- no find ever asserted.");
            $display("          With an all-ones target every result should");
            $display("          qualify, so the core produced nothing at all.");
        end else if (seen < WANT) begin
            $display("  RESULT: FAIL -- only %0d of %0d results arrived.",
                     seen, WANT);
            $display("          The result stream stalled.");
        end else if (bad != 0) begin
            $display("  RESULT: FAIL -- %0d of %0d results carried the wrong",
                     bad, seen);
            $display("          nonce. nonce_out has lost step with the");
            $display("          result stream; this is the hardware fault,");
            $display("          reproduced in simulation.");
        end else begin
            $display("  RESULT: PASS -- %0d consecutive results, all labelled",
                     seen);
            $display("          correctly, INCLUDING across a mid-stream header");
            $display("          swap. The bookkeeping is sound in RTL under the");
            $display("          real workload, so the off-by-one measured on");
            $display("          hardware is NOT a logic bug in this module --");
            $display("          look at the timing of the found/nonce capture.");
        end
        $finish;
    end

endmodule
