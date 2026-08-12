`timescale 1ns/1ps
// Does NONCE_BASE actually split the nonce space? Probe the two
// instances' internal nonce counters directly -- no need to wait for
// warm-up, the divergence is visible immediately after start_hash.
module tb;
    reg clk = 0; always #5 clk = ~clk;
    reg [607:0] header = 608'hDEADBEEF;
    reg [255:0] target; reg start_hash = 0;
    wire t2m_a, t2m_b; wire [31:0] n_a, n_b;

    miner_top #(.NONCE_BASE(32'h00000000)) A
        (.osc_clk(clk),.header(header),.target(target),
         .start_hash(start_hash),.ticket2moon(t2m_a),.nonce(n_a));
    miner_top #(.NONCE_BASE(32'h80000000)) B
        (.osc_clk(clk),.header(header),.target(target),
         .start_hash(start_hash),.ticket2moon(t2m_b),.nonce(n_b));

    integer errs = 0;
    initial begin
        target = {256{1'b1}};
        repeat (4) @(posedge clk);
        start_hash = 0; @(posedge clk);
        $display("=== at reset (start_hash low) ===");
        $display("  A.nonce_in = %08x   (expect 00000000)", A.miner.nonce_in);
        $display("  B.nonce_in = %08x   (expect 80000000)", B.miner.nonce_in);
        if (A.miner.nonce_in !== 32'h00000000) errs = errs + 1;
        if (B.miner.nonce_in !== 32'h80000000) errs = errs + 1;
        if (A.miner.nonce_out !== 32'h00000000) errs = errs + 1;
        if (B.miner.nonce_out !== 32'h80000000) errs = errs + 1;

        start_hash = 1;
        repeat (40) @(posedge clk);
        $display("=== after 40 cycles of hashing ===");
        $display("  A.nonce_in = %08x", A.miner.nonce_in);
        $display("  B.nonce_in = %08x", B.miner.nonce_in);
        $display("  separation = %08x  (expect ~80000000, i.e. still half the space apart)",
                 B.miner.nonce_in - A.miner.nonce_in);
        if ((B.miner.nonce_in - A.miner.nonce_in) !== 32'h80000000) errs = errs + 1;
        if (A.miner.nonce_in === B.miner.nonce_in) begin
            $display("  FAIL: both instances sweeping the SAME nonce -- duplicated work");
            errs = errs + 1;
        end
        $display("");
        // NB: do NOT collapse this into a ternary between two string
        // literals -- Verilog treats them as numeric vectors of
        // differing width and $display prints garbage.
        if (errs == 0)
            $display("RESULT: PASS -- nonce space cleanly split, no duplicated work");
        else
            $display("RESULT: FAIL -- %0d check(s) failed", errs);
        $finish;
    end
endmodule
