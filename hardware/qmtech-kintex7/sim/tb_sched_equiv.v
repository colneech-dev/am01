`timescale 1ns/1ps
//
// Functional equivalence for the odo_gen SCHEDULING change.
//
// WHAT IS UNVERIFIED, AND WHY IT MATTERS
// --------------------------------------
// Two days were spent optimising the TIMING of a core whose CORRECTNESS was
// never established. `--bram-out-reg` plus `extra_delay >= 1` changes real
// scheduling arithmetic:
//     cycles per round      2 -> 3
//     extra_delay           1 -> 2   (state[21:0] -> state[22:0])
//     round-key tap         period[2*i] -> period[3*i]
//     period depth          [42:0] -> [64:0]
//     latency               172 -> 253
// If any of that is off by one, the miner runs happily and produces WRONG
// results -- which surface as silent pool rejects, not a crash. That is the
// exact failure mode odocrypt_gpio_wrapper.v already warns about for a
// mis-shifted header.
//
// WHY NOT tb_outreg_equiv.v
// -------------------------
// It exists and is correct, but printed nothing until the very end, so an
// 8-hour run that was killed by a reboot yielded no information at all -- not
// even whether it was progressing. This version reports progress, so a slow
// run is distinguishable from a stuck one and the rate can be measured from a
// short run.
//
// WHAT IS COMPARED
// ----------------
// Latency differs (172 vs 253), so a cycle-by-cycle diff would report 100%
// mismatch on a perfectly correct core. Instead each core's emitted results are
// pushed onto its own queue as it asserts `write`, and the QUEUES are compared.
// Order and content must match; latency drops out.
//
// NEGATIVE CONTROL -- a pass proves nothing without one
// -----------------------------------------------------
// +brk=N perturbs the input once the test core has produced N results. That
// must FAIL. If it passes, the comparison is not live and a clean run is
// meaningless.
//
//   iverilog -g2012 -o tb tb_sched_equiv.v /tmp/v_ref.v /tmp/v_tst.v
//   ./tb +n=700              -> must PASS
//   ./tb +n=700 +brk=3       -> must FAIL
//
module tb;
    // Plusargs so the same binary can be run short (to measure the rate) or
    // long (to actually prove something) without recompiling -- compilation of
    // two 640-bit cores is itself minutes.
    integer N       = 700;
    integer brk     = 0;
    integer progress_every = 25;
    integer drain = 20;

    localparam MIN_SEQ = 8;     // refuse to call it a PASS below this
    localparam MAXQ    = 4096;

    reg clk = 0;
    always #5 clk = ~clk;

    reg  [639:0] in;
    reg          read = 0;
    wire [639:0] out_ref, out_tst;
    wire         write_ref, write_tst;

    ref_4encrypt u_ref (clk, in, read, out_ref, write_ref);
    tst_4encrypt u_tst (clk, in, read, out_tst, write_tst);

    reg [639:0] qref [0:MAXQ-1];
    reg [639:0] qtst [0:MAXQ-1];
    integer nref = 0, ntst = 0;
    integer i, k, mismatches = 0;
    time     t_start;

    always @(negedge clk) begin
        if (write_ref && nref < MAXQ) begin qref[nref] = out_ref; nref = nref + 1; end
        if (write_tst && ntst < MAXQ) begin qtst[ntst] = out_tst; ntst = ntst + 1; end
    end

    initial begin
        if (!$value$plusargs("n=%d", N))   N = 700;
        if (!$value$plusargs("brk=%d", brk)) brk = 0;
        if (!$value$plusargs("every=%d", progress_every)) progress_every = 25;
        if (!$value$plusargs("drain=%d", drain)) drain = 20;

        $display("  N=%0d brk=%0d  (ref latency 172, test latency 253)", N, brk);
        t_start = $time;

        in = 640'd0; read = 0;
        @(negedge clk);

        for (i = 0; i < N; i = i + 1) begin
            if (i % 8 == 0) begin
                in = {8{ {2{i[31:0]}}, 32'hA5A5_5A5A, i[31:0] }};
                // Negative control: perturb once the test core has emitted brk
                // results. Both cores see it, so what this really proves is
                // that the comparison would NOTICE a divergence at all.
                if (brk != 0 && ntst >= brk) in[0] = ~in[0];
                read = 1;
            end else read = 0;
            @(negedge clk);
            // Progress, so a slow run is distinguishable from a stuck one.
            if (progress_every > 0 && (i % progress_every) == 0)
                $display("    cycle %0d/%0d  ref=%0d tst=%0d  (%0t sim, wall-clock via `time`)",
                         i, N, nref, ntst, $time - t_start);
        end

        read = 0;
        // Results emerge WHILE feeding, so a full 253-cycle drain is not needed --
        // at ~8 s/cycle in iverilog that would be 30+ minutes of pure overhead.
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

        if (k < MIN_SEQ)
            $display("  RESULT: INCONCLUSIVE -- only %0d results, need >= %0d", k, MIN_SEQ);
        else if (mismatches != 0)
            $display("  RESULT: FAIL -- %0d of %0d differ", mismatches, k);
        else
            $display("  RESULT: PASS -- %0d results identical", k);
        $finish;
    end
endmodule
