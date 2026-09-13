// tb_found_path_multi -- does found_path keep EVERY find when more than two
// cores strobe at once?
//
// tb_found_path covers NUM_MINERS=2 thoroughly and cannot see this: with two
// cores the old collector (scan the first two, stash one) was already
// sufficient. The loss only appears at three or more, which is exactly the
// configuration hdl/mux4 builds and the reason found_path used to refuse to
// elaborate above two.
//
// The claim under test, from found_path.v:
//
//     a stash NUM_MINERS-1 deep loses nothing, because only one nonce can
//     enter the FIFO per cycle, the stash drains at one per cycle, and a core
//     cannot produce another result for THROUGHPUT cycles -- so the stash is
//     empty in time iff NUM_MINERS <= THROUGHPUT
//
// T3 tests that inequality AT ITS EDGE (4 and 4, where the stash empties on
// the very cycle the next batch may arrive), and T4 is the negative control
// that breaks it deliberately. Without T4 a passing T1-T3 would not
// distinguish "keeps everything" from "this testbench cannot see loss".
`timescale 1ns / 1ps

module tb_found_path_multi;

    localparam integer NM = 4;
    localparam integer TP = 4;

    reg               clk = 1'b0;
    reg               commit = 1'b0;
    reg               soft_reset = 1'b0;
    reg  [NM-1:0]     found_in = {NM{1'b0}};
    reg  [32*NM-1:0]  nonce_in_flat = {(32*NM){1'b0}};
    reg               ack_toggle = 1'b0;

    wire              nonce_toggle;
    wire [31:0]       nonce_latch;
    wire              report_ok;
    wire [7:0]        lost_count;
    wire [3:0]        fifo_count;

    integer pass = 0;
    integer fail = 0;

    task check(input cond, input [700:0] what);
    begin
        if (cond) begin
            pass = pass + 1;
            $display("  PASS  %0s", what);
        end else begin
            fail = fail + 1;
            $display("  FAIL  %0s", what);
        end
    end
    endtask

    found_path #(
        .NUM_MINERS   (NM),
        .THROUGHPUT   (TP),
        .SETTLE_CYCLES(4),
        .FIFO_AW      (3)
    ) dut (
        .clk          (clk),
        .commit       (commit),
        .soft_reset   (soft_reset),
        .found_in     (found_in),
        .nonce_in_flat(nonce_in_flat),
        .ack_toggle   (ack_toggle),
        .nonce_toggle (nonce_toggle),
        .nonce_latch  (nonce_latch),
        .report_ok    (report_ok),
        .lost_count   (lost_count),
        .fifo_count   (fifo_count)
    );

    always #5 clk = ~clk;

    // Drain whatever the DUT hands over, recording each nonce. The host side
    // is modelled as always ready, because this testbench is about the
    // COLLECTOR, not about back-pressure -- tb_found_path already covers a
    // host that stops reading.
    reg [31:0] seen [0:63];
    integer    n_seen = 0;
    reg        last_toggle = 1'b0;

    always @(posedge clk) begin
        if (nonce_toggle !== last_toggle) begin
            seen[n_seen] = nonce_latch;
            n_seen       = n_seen + 1;
            last_toggle  = nonce_toggle;
            ack_toggle  <= ~ack_toggle;
        end
    end

    function integer seen_has(input [31:0] want);
        integer i;
        begin
            seen_has = 0;
            for (i = 0; i < n_seen; i = i + 1)
                if (seen[i] === want) seen_has = 1;
        end
    endfunction

    // Strobe `n` cores in the same cycle, with nonce 0xNN0000 + core index.
    task strobe(input integer n, input [31:0] tag);
        integer i;
    begin
        for (i = 0; i < NM; i = i + 1) begin
            nonce_in_flat[32*i +: 32] = tag + i;
            found_in[i]               = (i < n);
        end
        @(posedge clk);
        #1;
        found_in = {NM{1'b0}};
    end
    endtask

    task settle(input integer cycles);
        integer i;
    begin
        for (i = 0; i < cycles; i = i + 1) @(posedge clk);
    end
    endtask

    task new_job;
    begin
        commit = 1'b1; @(posedge clk); #1; commit = 1'b0;
        // SETTLE_CYCLES=4 plus slack: finds before this are deliberately
        // suppressed and would confuse every count below.
        settle(12);
        n_seen = 0;
    end
    endtask

    integer i;

    initial begin
        $display("tb_found_path_multi: NUM_MINERS=%0d THROUGHPUT=%0d", NM, TP);
        $display("  does the collector keep every simultaneous find?");
        $display("");

        settle(4);
        new_job;

        // ---- T1: three at once -------------------------------------
        $display("-- T1: THREE cores strobe on one cycle --");
        strobe(3, 32'h00A0_0000);
        settle(20);
        check(n_seen == 3, "all three nonces handed over");
        check(seen_has(32'h00A0_0000) && seen_has(32'h00A0_0001) &&
              seen_has(32'h00A0_0002), "and they are the three that were found");
        check(lost_count == 8'd0, "nothing counted lost");
        $display("");

        // ---- T2: four at once --------------------------------------
        $display("-- T2: ALL FOUR cores strobe on one cycle --");
        new_job;
        strobe(4, 32'h00B0_0000);
        settle(20);
        check(n_seen == 4, "all four nonces handed over");
        check(seen_has(32'h00B0_0000) && seen_has(32'h00B0_0001) &&
              seen_has(32'h00B0_0002) && seen_has(32'h00B0_0003),
              "and they are the four that were found");
        check(lost_count == 8'd0, "nothing counted lost");
        $display("");

        // ---- T3: the edge of the proof -----------------------------
        // NUM_MINERS == THROUGHPUT, so the stash empties on the very cycle the
        // next batch may arrive. If the drain is off by one, this is where it
        // shows.
        //
        // TWO batches, not more, and the bound is deliberate. Four finds every
        // four cycles is ~1 find per cycle arriving, which outruns the
        // req/ack handoff no matter how the collector behaves: the FIFO
        // saturates and finds are lost to BACK-PRESSURE. That is a real
        // property but it is a host-rate question, already covered by
        // tb_found_path, and it would mask the stash behaviour this test
        // exists to check. Eight finds fit an 8-deep FIFO with room, so
        // anything lost here is the collector's doing.
        $display("-- T3: two batches of four, %0d cycles apart (the edge) --", TP);
        new_job;
        strobe(4, 32'h00C0_0000);
        settle(TP - 1);
        strobe(4, 32'h00C1_0000);
        settle(40);
        $display("     n_seen=%0d lost=%0d fifo=%0d", n_seen, lost_count, fifo_count);
        check(n_seen == 8, "all eight nonces over two adjacent batches");
        check(lost_count == 8'd0, "and none counted lost at the edge");
        check(seen_has(32'h00C0_0003) && seen_has(32'h00C1_0003),
              "including the LAST core of each batch, the first to be dropped");
        $display("");

        // ---- T4: NEGATIVE CONTROL ----------------------------------
        // Two batches ONE cycle apart, which breaks NUM_MINERS <= THROUGHPUT.
        // The stash holds 3; one drains, so only one slot is free when the
        // second batch of 4 arrives, and finds MUST be lost.
        //
        // The fifo check is the point of the control. Without it a non-zero
        // lost count would not distinguish "the stash overflowed" from "the
        // FIFO filled up", and T3 would prove nothing about the stash.
        $display("-- T4: NEGATIVE CONTROL, batches 1 cycle apart --");
        new_job;
        strobe(4, 32'h00D0_0000);
        strobe(4, 32'h00D1_0000);
        settle(40);
        $display("     n_seen=%0d lost=%0d fifo=%0d", n_seen, lost_count, fifo_count);
        check(lost_count != 8'd0,
              "finds ARE lost when the stash cannot drain (control)");
        check(fifo_count < 4'd8,
              "and the FIFO never filled -- so it was the STASH, not back-pressure");
        $display("");

        $display("");
        if (fail == 0) begin
            $display("=== ALL CHECKS PASSED (%0d) ===", pass);
        end else begin
            $display("=== %0d FAILURES of %0d checks ===", fail, pass + fail);
        end
        $finish;
    end

    initial begin
        #500000;
        $display("=== FAIL (timeout) ===");
        $finish;
    end

endmodule
