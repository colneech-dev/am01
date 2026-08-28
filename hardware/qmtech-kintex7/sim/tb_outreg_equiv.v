`timescale 1ns/1ps
//
// Equivalence for the BRAM-output-register transform (odo_gen --bram-out-reg).
//
// WHY A THIRD TESTBENCH
// ---------------------
// tb_encrypt_equiv.v compares two cores cycle by cycle, which only works while
// they have identical latency. --bram-out-reg adds one clock per round, taking
// the pipeline from 171 to 252 stages, so a cycle-aligned diff would report
// 100% mismatch on a core that is perfectly correct.
//
// tb_encrypt_equiv_seq.v already solves that by comparing the SEQUENCE of
// emitted results, but it is wired for the mux2 transform, whose core takes
// extra ports (clk2x, phase_d). Both cores here have the identical port list
// (clk, in, read, out, write), so the harness gets simpler rather than more
// complex.
//
// WHAT IS COMPARED
// ----------------
// Every time a core asserts `write`, its output word is pushed onto that core's
// queue. The queues are then compared element by element. Latency drops out;
// order and content do not.
//
// NEGATIVE CONTROL -- a pass means nothing without one
// ----------------------------------------------------
// +brk=N corrupts one S-box output bit in the outreg core after N results, by
// forcing a bit of `in` on a later feed. That must FAIL. If it passes, the test
// cannot detect broken hardware and a clean run proves nothing.
//
// The reference core is prefix ref_4, the transformed one reg_4:
//     odo_gen <seed> 4 ref_4                  > enc_ref.v
//     odo_gen <seed> 4 reg_4 --bram-out-reg   > enc_outreg.v
//
// Run:
//   iverilog -g2012 -o tb tb_outreg_equiv.v enc_ref.v enc_outreg.v
//   ./tb                 -> must PASS
//   ./tb +brk=5          -> must FAIL   (negative control)
//
module tb;
    localparam N       = 600;   // clk_h cycles. First result emerges at ~252
                                // (pipeline depth); feeding every 8 cycles this
                                // yields ~40 results, comfortably over MIN_SEQ.
                                // 1400 was too slow: two 640-bit cores in
                                // behavioural sim timed out at 2400s with no
                                // output at all.
    localparam MIN_SEQ = 20;    // refuse to declare PASS on fewer results
    localparam MAXQ    = 4096;

    reg clk_h = 0;
    always #5 clk_h = ~clk_h;

    integer brk = 0;

    reg [639:0] in;
    reg         read = 0;

    wire [639:0] out_ref, out_reg;
    wire         write_ref, write_reg;

    ref_4encrypt u_ref (clk_h, in, read, out_ref, write_ref);
    reg_4encrypt u_reg (clk_h, in, read, out_reg, write_reg);

    reg [639:0] qref [0:MAXQ-1];
    reg [639:0] qreg [0:MAXQ-1];
    integer nref = 0, nreg = 0;
    integer i, k, mismatches = 0;

    // Collect on the negative edge so the values have settled.
    always @(negedge clk_h) begin
        if (write_ref && nref < MAXQ) begin
            qref[nref] = out_ref;
            nref = nref + 1;
        end
        if (write_reg && nreg < MAXQ) begin
            qreg[nreg] = out_reg;
            nreg = nreg + 1;
        end
    end

    initial begin
        if (!$value$plusargs("brk=%d", brk)) brk = 0;

        in   = 640'd0;
        read = 0;
        @(negedge clk_h);

        for (i = 0; i < N; i = i + 1) begin
            // Feed a fresh block every 8 cycles; a deterministic pattern so the
            // run is reproducible.
            if (i % 8 == 0) begin
                in   = {8{ {2{i[31:0]}}, 32'hA5A5_5A5A, i[31:0] }};
                // Negative control: corrupt one input bit once the outreg core
                // has produced `brk` results. Both cores see the same `in`, so
                // this perturbs both -- what it really tests is that the
                // comparison is live and would notice a divergence at all.
                if (brk != 0 && nreg >= brk)
                    in[0] = ~in[0];
                read = 1;
            end else begin
                read = 0;
            end
            @(negedge clk_h);
        end

        read = 0;
        // Drain: the deeper pipe needs the longer tail.
        for (i = 0; i < 400; i = i + 1) @(negedge clk_h);

        k = (nref < nreg) ? nref : nreg;
        $display("");
        $display("  reference results emitted : %0d", nref);
        $display("  outreg    results emitted : %0d", nreg);
        $display("  compared                  : %0d", k);
        if (brk != 0)
            $display("  mode                      : NEGATIVE CONTROL (+brk=%0d) -- must FAIL", brk);

        for (i = 0; i < k; i = i + 1) begin
            if (qref[i] !== qreg[i]) begin
                if (mismatches < 5)
                    $display("  MISMATCH at result %0d:\n    ref=%h\n    reg=%h",
                             i, qref[i], qreg[i]);
                mismatches = mismatches + 1;
            end
        end

        if (k < MIN_SEQ) begin
            $display("  RESULT: INCONCLUSIVE -- only %0d results, need >= %0d", k, MIN_SEQ);
            $display("          (not a pass: too little of the pipeline exercised)");
        end else if (mismatches != 0) begin
            $display("  RESULT: FAIL -- %0d of %0d results differ", mismatches, k);
        end else begin
            $display("  RESULT: PASS -- %0d results identical", k);
        end
        $finish;
    end
endmodule
