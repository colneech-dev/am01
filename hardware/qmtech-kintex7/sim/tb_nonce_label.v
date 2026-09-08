`timescale 1ns/1ps
//
// Do miner_pipelined's two nonce counters stay in step?
//
// WHY
// ---
// Measured on hardware 2026-09-07: recomputing every rejected find's digest at
// nonce-4..nonce+4 showed ~80% of them were the CORRECT digest carrying a nonce
// exactly one too high, on both instances, with every other offset at zero.
// The cipher is not the problem -- tb_encrypt_oracle proves encrypt.v matches
// the software oracle byte for byte at the shipping epoch. The label is.
//
// miner_pipelined keeps two counters (hdl/odocrypt/miner_pipelined.v:62-65):
//
//     nonce_in    feeds the cipher,    incremented on `advance`
//     nonce_out   shadows the results, incremented on `has_res`
//
// Neither is ever reset; both are `initial`-ised to INONCE once at
// configuration, and the design ASSUMES one has_res per advance for ever. Any
// result the pipeline emits that did not come from an advance -- or any advance
// that never produces one -- shifts nonce_out against nonce_in permanently.
//
// WHAT THE FIRST VERSION OF THIS FILE GOT WRONG
// ---------------------------------------------
// It asserted that the REPORTED nonce increments by exactly 1 on each find, and
// it passed. That assertion is vacuous. In the DUT:
//
//     if (has_res) begin
//         if (res) begin nonce <= nonce_out; found <= 1'b1; end
//         nonce_out <= nonce_out + 1;
//     end
//
// With an all-ones target `res` is always 1, so `nonce` is loaded from
// nonce_out on exactly the edges nonce_out increments. Consecutive reported
// values differ by 1 AS AN IDENTITY OF THE RTL, whatever the counters are doing
// relative to each other. An unpaired has_res produces a found, a nonce and a
// +1, indistinguishable from a legitimate result -- so the test could not
// detect the one fault it was written for, and its PASS meant nothing. That was
// found by review, not by the test failing, which is precisely the problem with
// a test that cannot fail.
//
// WHAT IT CHECKS NOW
// ------------------
// The desync directly, through hierarchical references: once the pipeline is
// full, (nonce_in - nonce_out) is the number of candidates in flight and must
// be CONSTANT. Every unpaired advance or unpaired has_res moves it, and that
// difference is exactly the offset by which a find will be mislabelled.
// Independently it counts advance and has_res pulses, whose difference must
// hold at the same constant.
//
// STILL OUT OF SCOPE, AND SAYING SO. This drives miner_pipelined alone. The
// off-by-one could equally live in found_path.v's collector or in the wrapper's
// nonce_flat_h capture; neither is instantiated here. And no functional
// simulation can speak to a synthesised core at 225MHz, which is the leading
// hypothesis for the hardware fault. A PASS here narrows the search. It does
// not close it.

module tb_nonce_label;

    localparam [31:0] INONCE_P = 32'h0000_0000;
    localparam integer WANT    = 24;    // results to observe after the first

    reg clk = 1'b0;
    always #5 clk = ~clk;

    // 19 x 32 bits = 608. Any header will do: this tests bookkeeping, not the
    // cipher, and tb_encrypt_oracle covers the cipher.
    reg [607:0] header = {19{32'h9e3779b9}};

    // All ones: every candidate qualifies, so `found` fires on every result and
    // the whole result stream is observable. cmp_256 computes (greater < less)
    // and no 16-bit lane can exceed 0xFFFF, so greater is 0 and out is 1.
    reg [255:0] target = {256{1'b1}};

    wire [31:0] nonce;
    wire        found;

    miner_pipelined #(.INONCE(INONCE_P)) dut (
        .clk(clk), .header(header), .target(target),
        .nonce(nonce), .found(found)
    );

    integer  seen       = 0;
    integer  cycles     = 0;
    integer  adv_count  = 0;
    integer  res_count  = 0;
    integer  drifts     = 0;
    reg      started    = 1'b0;
    reg [31:0] delta0   = 32'h0;    // in-flight count once the pipe is full
    integer  pulse_gap0 = 0;

    // The real assertion. nonce_in leads nonce_out by however many candidates
    // are in flight: constant once filled, and any change is the desync that
    // mislabels finds.
    wire [31:0] delta_now = dut.nonce_in - dut.nonce_out;

    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (dut.advance) adv_count <= adv_count + 1;
        if (dut.has_res) res_count <= res_count + 1;

        if (found) begin
            if (!started) begin
                started    <= 1'b1;
                delta0     <= delta_now;
                pulse_gap0 <= adv_count - res_count;
                $display("  pipeline full at cycle %0d: nonce_in leads nonce_out by %0d",
                         cycles, delta_now);
            end else begin
                seen <= seen + 1;
                if (delta_now !== delta0) begin
                    drifts <= drifts + 1;
                    if (drifts < 8)
                        $display("  DESYNC at result %0d cycle %0d: lead was %0d now %0d",
                                 seen, cycles, delta0, delta_now);
                end
                if ((adv_count - res_count) !== pulse_gap0) begin
                    drifts <= drifts + 1;
                    if (drifts < 8)
                        $display("  PULSE IMBALANCE at result %0d cycle %0d: advance-has_res was %0d now %0d",
                                 seen, cycles, pulse_gap0, adv_count - res_count);
                end
            end
        end
    end

    initial begin
        $display("tb_nonce_label: do miner_pipelined's nonce counters stay in step?");
        $display("  nonce_in leads nonce_out by the number of candidates in");
        $display("  flight. That lead must never change once the pipe is full;");
        $display("  any change IS the off-by-one seen on hardware.");
        $display("");

        // 259-stage pipeline, THROUGHPUT 4: first result ~265 cycles out, one
        // every 4 after. Fails on timeout rather than hanging.
        repeat (265 + WANT * 4 + 60) @(posedge clk);

        $display("");
        $display("  advances %0d, results %0d, finds observed %0d",
                 adv_count, res_count, seen);
        if (!started) begin
            $display("  RESULT: FAIL -- no find ever asserted. With an all-ones");
            $display("          target every result should qualify, so the core");
            $display("          produced nothing at all.");
        end else if (seen < WANT) begin
            $display("  RESULT: FAIL -- only %0d of %0d results arrived; the",
                     seen, WANT);
            $display("          result stream stalled.");
        end else if (drifts != 0) begin
            $display("  RESULT: FAIL -- the counters drifted %0d time(s). That is",
                     drifts);
            $display("          the hardware fault reproduced in simulation:");
            $display("          nonce_out has lost step with nonce_in, so finds");
            $display("          carry a nonce offset by the drift.");
        end else begin
            $display("  RESULT: PASS -- the lead held at %0d across %0d results.",
                     delta0, seen);
            $display("          The counters stay in step in RTL, so the");
            $display("          off-by-one on hardware is not a desync in this");
            $display("          module. NOT ruled out: found_path, the wrapper's");
            $display("          capture, and analogue timing -- none of which");
            $display("          this testbench can see.");
        end
        $finish;
    end

endmodule
