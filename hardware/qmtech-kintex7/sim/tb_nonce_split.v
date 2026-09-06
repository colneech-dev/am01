`timescale 1ns/1ps
//
// Does the nonce base actually split the nonce space between instances?
//
// RETARGETED 2026-09-06 AT THE CORE THAT SHIPS. This testbench used to
// instantiate miner_top with NONCE_BASE -- the AtomMiner core that 0x0200
// replaced. The design has instantiated miner_pipelined with INONCE since
// then, so the one test the sim README calls irreplaceable was guarding a
// module the bitstream does not contain:
//
//   "Guards the multi-instance change ... Resource counts cannot catch that;
//    only this check can."
//
// It could not. If INONCE regressed, the design would still fit, still report
// two instances, still hash correctly -- and deliver zero extra hashrate,
// because both cores would sweep identical nonces. Invisible in utilisation,
// invisible in a share, visible only as half the expected MH/s.
//
// The bases come from odocrypt_gpio_wrapper.v:
//     .INONCE(gi * ((32'hFFFFFFFF / NUM_MINERS) + 32'h1))
// which is checked here directly rather than hand-copied, so a change to that
// expression fails this test rather than quietly halving the hashrate.
//
// Build (from this directory):
//   ODO=../../../hdl/odocrypt
//   iverilog -g2005 -DTHROUGHPUT=4 -o /tmp/tb tb_nonce_split.v \
//       $ODO/miner_pipelined.v $ODO/encrypt.v $ODO/keccak800.v
//   vvp /tmp/tb
//
module tb;
    // The wrapper's expression, reproduced as parameters so the arithmetic
    // itself is under test.
    localparam NUM_MINERS = 2;
    localparam [31:0] BASE0 = 32'd0 * ((32'hFFFFFFFF / NUM_MINERS) + 32'h1);
    localparam [31:0] BASE1 = 32'd1 * ((32'hFFFFFFFF / NUM_MINERS) + 32'h1);

    reg clk = 0; always #5 clk = ~clk;
    reg [607:0] header = 608'hDEADBEEF;
    reg [255:0] target;
    wire found_a, found_b;
    wire [31:0] n_a, n_b;

    miner_pipelined #(.INONCE(BASE0)) A
        (.clk(clk), .header(header), .target(target),
         .nonce(n_a), .found(found_a));
    miner_pipelined #(.INONCE(BASE1)) B
        (.clk(clk), .header(header), .target(target),
         .nonce(n_b), .found(found_b));

    integer errs = 0;

    initial begin
        target = {256{1'b1}};

        // miner_pipelined FREE-RUNS -- there is no start_hash to wait on, and
        // nonce_in/nonce_out carry INONCE from their initial blocks. That is
        // the divergence, visible before the first edge.
        #1;
        $display("=== at time 0, before any clock edge ===");
        $display("  NUM_MINERS = %0d", NUM_MINERS);
        $display("  BASE0 = %08x   (expect 00000000)", BASE0);
        $display("  BASE1 = %08x   (expect 80000000)", BASE1);
        if (BASE0 !== 32'h00000000) errs = errs + 1;
        if (BASE1 !== 32'h80000000) errs = errs + 1;

        $display("  A.nonce_in = %08x", A.nonce_in);
        $display("  B.nonce_in = %08x", B.nonce_in);
        if (A.nonce_in  !== BASE0) errs = errs + 1;
        if (B.nonce_in  !== BASE1) errs = errs + 1;
        if (A.nonce_out !== BASE0) errs = errs + 1;
        if (B.nonce_out !== BASE1) errs = errs + 1;

        repeat (40) @(posedge clk);
        $display("=== after 40 cycles ===");
        $display("  A.nonce_in = %08x", A.nonce_in);
        $display("  B.nonce_in = %08x", B.nonce_in);
        $display("  separation = %08x  (expect 80000000 -- still half the space)",
                 B.nonce_in - A.nonce_in);
        if ((B.nonce_in - A.nonce_in) !== 32'h80000000) errs = errs + 1;
        if (A.nonce_in === B.nonce_in) begin
            $display("  FAIL: both instances on the SAME nonce -- duplicated work");
            errs = errs + 1;
        end

        // THE FOUR-INSTANCE CASE, arithmetic only. hdl/mux4 builds with
        // NUM_MINERS=4, and 0xFFFFFFFF/4 + 1 = 0x40000000 must still give four
        // bases that do not overlap. Cheap to check and it costs no simulated
        // cycles.
        $display("=== the same expression at NUM_MINERS = 4 ===");
        begin : four
            integer i;
            reg [31:0] b [0:3];
            for (i = 0; i < 4; i = i + 1) begin
                b[i] = i * ((32'hFFFFFFFF / 4) + 32'h1);
                $display("  base[%0d] = %08x", i, b[i]);
            end
            for (i = 1; i < 4; i = i + 1) begin
                if ((b[i] - b[i-1]) !== 32'h40000000) begin
                    $display("  FAIL: base[%0d]-base[%0d] = %08x, expected 40000000",
                             i, i-1, b[i] - b[i-1]);
                    errs = errs + 1;
                end
                if (b[i] === b[i-1]) errs = errs + 1;
            end
        end

        $display("");
        // NB: do NOT collapse this into a ternary between two string
        // literals -- Verilog treats them as numeric vectors of differing
        // width and $display prints garbage.
        if (errs == 0)
            $display("RESULT: PASS -- nonce space cleanly split, no duplicated work");
        else
            $display("RESULT: FAIL -- %0d check(s) failed", errs);
        $finish;
    end
endmodule
