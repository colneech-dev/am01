// tb_found_path.v -- unit test for found_path.v (v2.0 result path).
//
// WHY THIS EXISTS. Four bitstreams in a row (0x0106..0x0109) shipped a
// nonce-reporting bug, and every one was found on hardware after a ~1h35m
// Vivado build and a flash cycle, because the logic could only be exercised
// by simulating the whole design -- which contains two 15.5k-line
// odo_encrypt pipelines. That was measured: a wrapper-level testbench got
// through exactly one register read in 15 minutes before being killed. So
// the result path was extracted into found_path.v, which has no dependency
// on the cipher, and this runs in well under a second.
//
// The invariants below need no software oracle: they are true of any correct
// implementation regardless of what the cipher computes.
//
// Run:
//   iverilog -g2005 -o /tmp/tb sim/tb_found_path.v hdl/found_path.v && vvp /tmp/tb

`timescale 1ns / 1ps

module tb_found_path;

    localparam integer NM     = 2;
    localparam integer SETTLE = 20;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg              commit   = 1'b0;
    reg  [NM-1:0]    found_in = {NM{1'b0}};
    reg  [32*NM-1:0] nonce_in = {(32*NM){1'b0}};
    reg              ack      = 1'b0;

    wire        nonce_toggle;
    wire [31:0] nonce_latch;
    wire        report_ok;
    wire [7:0]  lost_count;
    wire [3:0]  fifo_count;

    found_path #(.NUM_MINERS(NM), .SETTLE_CYCLES(SETTLE), .FIFO_AW(3)) dut (
        .clk          (clk),
        .commit       (commit),
        .found_in     (found_in),
        .nonce_in_flat(nonce_in),
        .ack_toggle   (ack),
        .nonce_toggle (nonce_toggle),
        .nonce_latch  (nonce_latch),
        .report_ok    (report_ok),
        .lost_count   (lost_count),
        .fifo_count   (fifo_count)
    );

    integer errors = 0;
    task check(input cond, input [1023:0] what);
        begin
            if (cond) $display("  PASS  %0s", what);
            else begin $display("  FAIL  %0s", what); errors = errors + 1; end
        end
    endtask

    // ---- a "host": drains whatever the handoff offers -------------------
    reg        prev_toggle = 1'b0;
    integer    drained     = 0;
    reg [31:0] got [0:255];
    reg        draining    = 1'b0;

    always @(posedge clk) begin
        if (draining && (nonce_toggle !== prev_toggle)) begin
            got[drained] = nonce_latch;
            drained      = drained + 1;
            prev_toggle  = nonce_toggle;
            ack          <= ~ack;      // exactly one ack per nonce consumed
        end
    end

    task pulse_commit;
        begin
            @(negedge clk); commit <= 1'b1;
            @(negedge clk); commit <= 1'b0;
        end
    endtask

    // Strobe `found` on the given instances for one cycle.
    task fire(input [NM-1:0] which, input [31:0] n0, input [31:0] n1);
        begin
            @(negedge clk);
            nonce_in[31:0]  <= n0;
            nonce_in[63:32] <= n1;
            found_in        <= which;
            @(negedge clk);
            found_in        <= {NM{1'b0}};
        end
    endtask

    integer i, ordered;
    reg     prev_toggle_probe;

    initial begin
        $display("=== tb_found_path: found_path.v (settle / FIFO / handoff) ===");
        $display("    NUM_MINERS=%0d SETTLE=%0d FIFO=8", NM, SETTLE);
        draining = 1'b0;

        repeat (5) @(negedge clk);

        // ---- T1: nothing is reportable before the first commit ----------
        check(report_ok === 1'b0, "report_ok low before any commit");
        fire(2'b01, 32'hAAAA0001, 32'h0);
        repeat (4) @(negedge clk);
        check(fifo_count === 4'd0,
              "a find before any commit is not queued (header is still garbage)");

        // ---- T2: the settle window suppresses -----------------------------
        pulse_commit;
        check(report_ok === 1'b0, "report_ok low immediately after commit");
        fire(2'b01, 32'hAAAA0002, 32'h0);
        repeat (4) @(negedge clk);
        check(fifo_count === 4'd0, "a find inside the settle window is suppressed");

        // ---- T3: ...and opens afterwards ---------------------------------
        repeat (SETTLE + 4) @(negedge clk);
        check(report_ok === 1'b1, "report_ok high once the window closes");

        // NOT a fifo_count check: the handoff pops the entry into the latch
        // as soon as it is idle, so an accepted find legitimately shows
        // fifo_count==0 while sitting in nonce_latch awaiting the host's ack.
        // What matters is that it was OFFERED -- the toggle flipped.
        prev_toggle_probe = nonce_toggle;
        fire(2'b01, 32'h11110001, 32'h0);
        repeat (4) @(negedge clk);
        check(nonce_toggle !== prev_toggle_probe,
              "a find after the window is offered to the host");

        // ---- T4: drained in order, nothing lost --------------------------
        draining = 1'b1;
        repeat (6) @(negedge clk);
        check(drained == 1, "the queued find reaches the host");
        check(got[0] === 32'h11110001, "and it is the nonce that was found");

        for (i = 0; i < 8; i = i + 1) begin
            fire(2'b01, 32'h22220000 + i[31:0], 32'h0);
            repeat (6) @(negedge clk);   // let the host keep up
        end
        repeat (20) @(negedge clk);

        ordered = 1;
        for (i = 1; i < drained; i = i + 1)
            if (got[i] <= got[i-1]) ordered = 0;
        check(drained == 9, "all 8 further finds drained (none dropped when acked)");
        check(ordered, "nonces arrive in the order they were found");
        check(lost_count === 8'h0, "lost counter still zero while the host keeps up");

        // ---- T5: simultaneous finds on both cores --------------------------
        // The cores run in lockstep off one clock, so this genuinely happens.
        // The stash is what keeps the second one.
        fire(2'b11, 32'h33330001, 32'h33330002);
        repeat (20) @(negedge clk);
        check(drained == 11, "BOTH of two simultaneous finds are kept (stash works)");
        check(lost_count === 8'h0, "and neither is counted as lost");

        // ---- T6: overflow is visible, not silent ---------------------------
        draining = 1'b0;             // host stops reading
        for (i = 0; i < 20; i = i + 1) begin
            fire(2'b01, 32'h44440000 + i[31:0], 32'h0);
            @(negedge clk);
        end
        repeat (4) @(negedge clk);
        check(fifo_count === 4'd8, "FIFO fills to its depth and stops");
        check(lost_count !== 8'h0, "overflow increments the lost counter");
        $display("    (lost=%0d after 20 finds into an unread 8-deep FIFO)", lost_count);

        // ---- T7: the handoff did not corrupt what it was holding -----------
        draining = 1'b1;
        repeat (100) @(negedge clk);
        check(fifo_count === 4'd0, "backlog drains once the host resumes");

        // ---- T8: a commit re-arms the suppression --------------------------
        pulse_commit;
        check(report_ok === 1'b0, "a later commit reopens the settle window");
        fire(2'b01, 32'h55550001, 32'h0);
        repeat (4) @(negedge clk);
        check(dut.fifo_count === 4'd0,
              "finds during the re-opened window are suppressed too");

        // ---- T9: a commit FLUSHES anything already queued -------------------
        // Finds queued before a job change were made against the OLD header
        // and cannot solve the new one. Handing them over would only give the
        // host nonces it must reject.
        draining = 1'b0;
        repeat (SETTLE + 4) @(negedge clk);   // reopen the window from T8
        for (i = 0; i < 5; i = i + 1) begin
            fire(2'b01, 32'h66660000 + i[31:0], 32'h0);
            @(negedge clk);
        end
        repeat (4) @(negedge clk);
        check(fifo_count !== 4'd0, "finds queue up while the host is not reading");

        pulse_commit;
        repeat (4) @(negedge clk);
        check(fifo_count === 4'd0, "a commit flushes the queued finds");

        // ---- T10: and the FIFO still works afterwards -----------------------
        // A flush that left the pointers inconsistent would look fine right
        // here and then hand out garbage forever, so prove it still carries a
        // nonce end to end.
        // The host has to take the one nonce that was already in the latch
        // when the commit landed: the flush deliberately does not clear `busy`
        // (yanking a nonce the host may be mid-read of is what the
        // end-of-read ack fix exists to prevent), so the handoff stays held
        // until that one is acked. Real hosts always do read it -- it is
        // offered with nonce_valid set -- and then attribute it to the new job
        // and reject it. One stale nonce per job change, by design.
        draining = 1'b1;
        repeat (20) @(negedge clk);        // let that stale one be consumed
        repeat (SETTLE + 4) @(negedge clk);
        drained = 0;
        fire(2'b01, 32'h77770001, 32'h0);
        repeat (20) @(negedge clk);
        check(drained == 1 && got[0] === 32'h77770001,
              "the FIFO still delivers correctly after a flush");

        // ---- T11: NEGATIVE CONTROL ------------------------------------------
        // Everything above would also pass if the settle window were wired
        // shut and suppressed finds forever, or if `fire` simply never
        // reached the DUT. ng_dut is an identical instance with
        // SETTLE_CYCLES=0, driven by the same stimulus: it must report the
        // find that the SETTLE=20 instance suppressed at T2. If this one ever
        // starts passing for the wrong reason, the checks above stop meaning
        // anything.
        //
        // docs/CODE-REVIEW-2026-08-30.md records tb_sched_equiv passing
        // against a deliberately broken scheduler for exactly this reason.
        check(ng_reported === 1'b1,
              "NEGATIVE CONTROL: with SETTLE=0 the same find IS reported");

        $display("");
        if (errors == 0) $display("=== ALL CHECKS PASSED ===");
        else             $display("=== %0d CHECK(S) FAILED ===", errors);
        $finish;
    end

    // ---- negative-control instance: identical, but no settle window --------
    wire        ng_toggle;
    wire [31:0] ng_latch;
    wire        ng_report_ok;
    wire [7:0]  ng_lost;
    wire [3:0]  ng_count;
    reg         ng_reported = 1'b0;
    reg         ng_prev     = 1'b0;

    found_path #(.NUM_MINERS(NM), .SETTLE_CYCLES(0), .FIFO_AW(3)) ng_dut (
        .clk          (clk),
        .commit       (commit),
        .found_in     (found_in),
        .nonce_in_flat(nonce_in),
        .ack_toggle   (1'b0),        // never acked: one offer is all we need
        .nonce_toggle (ng_toggle),
        .nonce_latch  (ng_latch),
        .report_ok    (ng_report_ok),
        .lost_count   (ng_lost),
        .fifo_count   (ng_count)
    );

    always @(posedge clk) begin
        if (ng_toggle !== ng_prev) begin
            ng_reported <= 1'b1;
            ng_prev     <= ng_toggle;
        end
    end

    initial begin
        #200000;
        $display("=== TIMEOUT ===");
        $finish;
    end

endmodule
