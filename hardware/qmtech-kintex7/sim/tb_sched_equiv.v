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
    // Set from a plusarg in an initial block that runs before any clock
    // edge, so in_tst is settled before the first read.
    integer brk     = 0;
    integer progress_every = 25;
    integer drain = 20;
    // How many blocks to feed. 0 = unlimited. With blocks=1 exactly one
    // block is in flight, so interleaving and read-phase effects cannot
    // contribute and any mismatch is the scheduling arithmetic itself.
    integer blocks = 0;

    localparam THROUGHPUT = 4;   // must match the odo_gen throughput argument
    localparam MIN_SEQ = 8;     // refuse to call it a PASS below this
    localparam MAXQ    = 4096;

    reg clk = 0;
    always #5 clk = ~clk;

    reg  [639:0] in;
    reg          read = 0;
    wire [639:0] out_ref, out_tst;
    wire         write_ref, write_tst;

    // NEGATIVE CONTROL: the test core gets its OWN input, identical to `in`
    // except once the control fires. Perturbing the shared `in` (which an
    // earlier version did) changes BOTH cores equally, so they still agree
    // and the control passes -- measured, +brk=3 gave PASS. A control that
    // cannot fail makes the positive result meaningless.
    wire [639:0] in_tst = (brk != 0 && fed >= brk) ? (in ^ 640'd1) : in;

    ref_4encrypt u_ref (clk, in,     read, out_ref, write_ref);
    tst_4encrypt u_tst (clk, in_tst, read, out_tst, write_tst);

    reg [639:0] qref [0:MAXQ-1];
    reg [639:0] qtst [0:MAXQ-1];
    integer nref = 0, ntst = 0;
    integer i, k, mismatches = 0;
    integer fed = 0;
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
        if (!$value$plusargs("blocks=%d", blocks)) blocks = 0;

        $display("  N=%0d brk=%0d blocks=%0d  (ref latency 172, test latency 253)",
                 N, brk, blocks);
        t_start = $time;

        in = 640'd0; read = 0;
        @(negedge clk);

        for (i = 0; i < N; i = i + 1) begin
            // Feed every THROUGHPUT cycles, matching miner.v: it asserts advance
            // (this core.s read) when counter == THROUGHPUT-1, i.e. 1 cycle in 4.
            // Feeding slower is NOT harmless -- state[0] is rewritten every cycle
            // (from in on read, else from the recirculation), so a read at the
            // wrong phase destroys an in-flight block. The two cores have
            // different pipeline depths (43 vs 65 period slots), so one fixed
            // cadence that is not the designed one corrupts them differently and
            // the comparison is meaningless. An 8-cycle cadence produced
            // FAIL -- 5 of 13 differ, with results 0-7 matching and divergence
            // only once the pipe filled: the signature of a harness fault, not
            // of broken scheduling arithmetic.
            if ((i % THROUGHPUT == 0) && (blocks == 0 || fed < blocks)) begin
                in = {8{ {2{i[31:0]}}, 32'hA5A5_5A5A, i[31:0] }};
                read = 1;
                fed = fed + 1;
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

        // Order matters. A detected mismatch is a FAIL at ANY sample size --
        // one differing result disproves equivalence. Too few samples only
        // means there is not enough evidence to declare a PASS.
        //
        // Testing k < MIN_SEQ first (as this did) made +blocks=1 print
        // INCONCLUSIVE even when the single result mismatched, so the verdict
        // read identically before and after the round-key bug was fixed. The
        // bug was caught only because the separate MISMATCH line prints too.
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
