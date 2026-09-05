`timescale 1ns/1ps
//
// Functional equivalence for the --lutram=N sbox conversion (Option A sizing,
// see RESULTS.md "Option A: single wide miner (THROUGHPUT=2) + LUTRAM
// conversion"). Converting a large S-box from block RAM to distributed RAM
// is a synthesis-attribute change only -- same schedule, same latency, same
// round-key arithmetic -- so unlike tb_sched_equiv.v this compares two
// IDENTICALLY-scheduled cores (both THROUGHPUT=2, both --bram-out-reg) that
// differ only in --lutram=3 vs --lutram=0. A pass here isolates the
// conversion itself as behaviour-neutral; it says nothing about placement,
// timing, or BRAM/LUT resource counts, which are verified separately.
//
// WHAT IS COMPARED
// -----------------
// Same method as tb_sched_equiv.v: each core's emitted results are queued as
// `write` fires, and the queues are compared in order. Latency is identical
// here (both 254), so this also happens to be a valid cycle-aligned
// comparison, but the queue method is kept for consistency with the proven
// harness rather than assuming that alignment holds.
//
// NEGATIVE CONTROL -- a pass proves nothing without one
// -----------------------------------------------------
// +brk=N perturbs the test core's input once it has produced N results.
// That must FAIL, or the comparison is not live.
//
//   iverilog -g2012 -o tb tb_lutram_equiv.v /tmp/v_ref.v /tmp/v_tst.v
//   ./tb +n=700              -> must PASS
//   ./tb +n=700 +brk=3       -> must FAIL
//
module tb;
    integer N       = 700;
    integer brk     = 0;
    integer progress_every = 25;
    integer drain = 20;
    integer blocks = 0;

    localparam THROUGHPUT = 4;   // must match the odo_gen throughput argument
    localparam MIN_SEQ = 8;
    localparam MAXQ    = 4096;

    reg clk = 0;
    always #5 clk = ~clk;

    reg  [639:0] in;
    reg          read = 0;
    wire [639:0] out_ref, out_tst;
    wire         write_ref, write_tst;

    wire [639:0] in_tst = (brk != 0 && fed >= brk) ? (in ^ 640'd1) : in;

    ref_4encrypt u_ref (clk, in,     read, out_ref, write_ref);
    tst_4encrypt u_tst (clk, in_tst, read, out_tst, write_tst);

    reg [639:0] qref [0:MAXQ-1];
    reg [639:0] qtst [0:MAXQ-1];
    // v2's central claim is that it adds NO latency (total_r is captured on
    // the same edge as state[0], from the same source). Comparing values
    // alone would not catch a latency shift -- the sequences would still
    // match while every result arrived a cycle late. So record emission
    // times too and require them to be identical.
    time tref [0:MAXQ-1];
    time ttst [0:MAXQ-1];
    integer nref = 0, ntst = 0;
    integer i, k, mismatches = 0, lat_shift = 0;
    integer fed = 0;
    time     t_start;

    always @(negedge clk) begin
        if (write_ref && nref < MAXQ) begin qref[nref] = out_ref; tref[nref] = $time; nref = nref + 1; end
        if (write_tst && ntst < MAXQ) begin qtst[ntst] = out_tst; ttst[ntst] = $time; ntst = ntst + 1; end
    end

    initial begin
        if (!$value$plusargs("n=%d", N))   N = 700;
        if (!$value$plusargs("brk=%d", brk)) brk = 0;
        if (!$value$plusargs("every=%d", progress_every)) progress_every = 25;
        if (!$value$plusargs("drain=%d", drain)) drain = 20;
        if (!$value$plusargs("blocks=%d", blocks)) blocks = 0;

        $display("  N=%0d brk=%0d blocks=%0d  (ref = plain pre-mix, tst = --pipeline-premix v2)",
                 N, brk, blocks);
        t_start = $time;

        in = 640'd0; read = 0;
        @(negedge clk);

        for (i = 0; i < N; i = i + 1) begin
            if ((i % THROUGHPUT == 0) && (blocks == 0 || fed < blocks)) begin
                in = {8{ {2{i[31:0]}}, 32'hA5A5_5A5A, i[31:0] }};
                read = 1;
                fed = fed + 1;
            end else read = 0;
            @(negedge clk);
            if (progress_every > 0 && (i % progress_every) == 0)
                $display("    cycle %0d/%0d  ref=%0d tst=%0d  (%0t sim, wall-clock via `time`)",
                         i, N, nref, ntst, $time - t_start);
        end

        read = 0;
        for (i = 0; i < drain; i = i + 1) @(negedge clk);

        k = (nref < ntst) ? nref : ntst;
        $display("");
        $display("  reference results : %0d", nref);
        $display("  test      results : %0d", ntst);
        $display("  compared          : %0d", k);

        for (i = 0; i < k; i = i + 1)
            if (tref[i] !== ttst[i]) begin
                if (lat_shift < 3)
                    $display("  LATENCY SHIFT %0d: ref@%0t tst@%0t", i, tref[i], ttst[i]);
                lat_shift = lat_shift + 1;
            end
        if (lat_shift != 0)
            $display("  NOTE: %0d of %0d results moved in time -- v2 must add no latency",
                     lat_shift, k);

        for (i = 0; i < k; i = i + 1)
            if (qref[i] !== qtst[i]) begin
                if (mismatches < 3)
                    $display("  MISMATCH %0d:\n    ref=%h\n    tst=%h", i, qref[i], qtst[i]);
                mismatches = mismatches + 1;
            end

        if (mismatches != 0)
            $display("  RESULT: FAIL -- %0d of %0d differ", mismatches, k);
        else if (lat_shift != 0)
            $display("  RESULT: FAIL -- values match but %0d of %0d shifted in time", lat_shift, k);
        else if (k < MIN_SEQ)
            $display("  RESULT: INCONCLUSIVE -- only %0d results, need >= %0d (no mismatches seen)",
                     k, MIN_SEQ);
        else
            $display("  RESULT: PASS -- %0d results identical", k);
        $finish;
    end
endmodule
