`timescale 1ns/1ps
//
// Functional equivalence for the THROUGHPUT=3 core against the verified
// THROUGHPUT=4 reference.
//
// WHY THIS IS NOT OPTIONAL
// -----------------------
// THROUGHPUT=3 changes real scheduling arithmetic, not just a rate:
//     unrolling      21 -> 28      (odo_gen: (ROUNDS-1)/throughput + 1)
//     periods         4 -> 3
//     extra_delay     2 -> 1       (the gcd(throughput, RoundCycles*unrolling
//                                   + extra_delay) == 1 search lands elsewhere)
//     latency       259 -> 255
// If any of that is off by one the miner runs at full speed and emits WRONG
// digests -- silent pool rejects, not a crash. This project has already been
// bitten by exactly that: the round-key tap bug voided every --bram-out-reg
// measurement taken before it was found. A timing number for an unverified
// core is worth nothing.
//
// WHAT IS COMPARED, AND WHY NOT CYCLE-BY-CYCLE
// -------------------------------------------
// The two cores consume input at DIFFERENT rates (one block per 4 clocks vs
// per 3) and have different latencies, so a cycle-wise diff would report
// mismatch on a perfectly correct pair. Each core is therefore fed its own
// cadence from the SAME sequence of input values -- input k is a pure
// function of that core's own feed index, so both see identical data -- and
// the emitted result SEQUENCES are compared. Order and content must match;
// rate and latency drop out.
//
// NEGATIVE CONTROL -- a pass proves nothing without one
// -----------------------------------------------------
// +brk=N perturbs the test core's input from its Nth block onward. That must
// FAIL. Perturbing a shared input would change both cores equally and still
// agree, which is why each core has its own input register here.
//
//   iverilog -g2012 -o tb tb_t3_equiv.v /tmp/v_t4.v /tmp/v_t3.v
//   ./tb +n=800            -> must PASS
//   ./tb +n=800 +brk=3     -> must FAIL
//
module tb;
    integer N       = 800;
    integer brk     = 0;
    integer progress_every = 50;
    integer drain   = 20;

    localparam T_REF = 4;   // reference core: clocks per block
    localparam T_TST = 3;   // test core:      clocks per block
    localparam MIN_SEQ = 8;
    localparam MAXQ    = 4096;

    reg clk = 0;
    always #5 clk = ~clk;

    reg  [639:0] in_ref, in_tst;
    reg          read_ref = 0, read_tst = 0;
    wire [639:0] out_ref, out_tst;
    wire         write_ref, write_tst;

    ref_4encrypt u_ref (clk, in_ref, read_ref, out_ref, write_ref);
    tst_3encrypt u_tst (clk, in_tst, read_tst, out_tst, write_tst);

    reg [639:0] qref [0:MAXQ-1];
    reg [639:0] qtst [0:MAXQ-1];
    integer nref = 0, ntst = 0;
    integer i, k, mismatches = 0;
    integer fed_ref = 0, fed_tst = 0;
    time    t_start;

    always @(negedge clk) begin
        if (write_ref && nref < MAXQ) begin qref[nref] = out_ref; nref = nref + 1; end
        if (write_tst && ntst < MAXQ) begin qtst[ntst] = out_tst; ntst = ntst + 1; end
    end

    initial begin
        if (!$value$plusargs("n=%d", N))     N = 800;
        if (!$value$plusargs("brk=%d", brk)) brk = 0;
        if (!$value$plusargs("every=%d", progress_every)) progress_every = 50;
        if (!$value$plusargs("drain=%d", drain)) drain = 20;

        $display("  N=%0d brk=%0d  (ref T=%0d latency 259, tst T=%0d latency 255)",
                 N, brk, T_REF, T_TST);
        t_start = $time;

        in_ref = 640'd0; in_tst = 640'd0;
        read_ref = 0; read_tst = 0;
        @(negedge clk);

        for (i = 0; i < N; i = i + 1) begin
            // Each core is fed at its OWN cadence, but block k carries the
            // same value for both -- the value is a function of the core's
            // feed index, never of the cycle number.
            if (i % T_REF == 0) begin
                in_ref = {8{ {2{fed_ref[31:0]}}, 32'hA5A5_5A5A, fed_ref[31:0] }};
                read_ref = 1;
                fed_ref  = fed_ref + 1;
            end else read_ref = 0;

            if (i % T_TST == 0) begin
                in_tst = {8{ {2{fed_tst[31:0]}}, 32'hA5A5_5A5A, fed_tst[31:0] }};
                // Negative control: corrupt the test core's data only.
                if (brk != 0 && fed_tst >= brk)
                    in_tst = in_tst ^ 640'd1;
                read_tst = 1;
                fed_tst  = fed_tst + 1;
            end else read_tst = 0;

            @(negedge clk);
            if (progress_every > 0 && (i % progress_every) == 0)
                $display("    cycle %0d/%0d  fed %0d/%0d  results ref=%0d tst=%0d  (%0t sim)",
                         i, N, fed_ref, fed_tst, nref, ntst, $time - t_start);
        end

        read_ref = 0; read_tst = 0;
        for (i = 0; i < drain; i = i + 1) @(negedge clk);

        k = (nref < ntst) ? nref : ntst;
        $display("");
        $display("  reference results : %0d", nref);
        $display("  test      results : %0d", ntst);
        $display("  compared          : %0d", k);

        for (i = 0; i < k; i = i + 1)
            if (qref[i] !== qtst[i]) begin
                if (mismatches < 3)
                    $display("  MISMATCH %0d:\n    ref=%h\n    tst=%h", i, qref[i], qtst[i]);
                mismatches = mismatches + 1;
            end

        // A detected mismatch is a FAIL at ANY sample size -- one differing
        // result disproves equivalence. Too few samples only means there is
        // not enough evidence to declare a PASS, so that test comes second.
        if (mismatches != 0)
            $display("  RESULT: FAIL -- %0d of %0d differ", mismatches, k);
        else if (k < MIN_SEQ)
            $display("  RESULT: INCONCLUSIVE -- only %0d results, need >= %0d (no mismatches seen)",
                     k, MIN_SEQ);
        else
            $display("  RESULT: PASS -- %0d results identical", k);
        $finish;
    end
endmodule
