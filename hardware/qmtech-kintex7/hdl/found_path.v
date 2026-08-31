// found_path.v -- settle window, found FIFO and cross-domain handoff for the
// free-running miner cores. Extracted from odocrypt_gpio_wrapper.v at v2.0.
//
// WHY IT IS ITS OWN MODULE. This is the logic that four consecutive
// bitstreams (0x0106..0x0109) got wrong, each discovered only on hardware
// after a ~1h35m build and a flash. Inside the wrapper it could only be
// exercised by simulating the whole design, and the whole design contains
// two 15.5k-line odo_encrypt pipelines -- a run measured in hours, which in
// practice means it never gets run. Pulled out here it has no dependency on
// the cipher at all and tb_found_path exercises every path in well under a
// second. Testability was the point.
//
// WHAT IT DOES
//   * suppresses found-reporting for SETTLE_CYCLES after each job commit,
//     because the pipeline still holds in-flight nonces hashed against the
//     PREVIOUS header and those can spuriously qualify against the new target
//   * accepts up to two simultaneous finds (the cores run in lockstep off one
//     clock, so they genuinely can strobe together) into an 8-deep FIFO
//   * hands nonces to the bus domain one at a time over a two-phase
//     req/ack toggle pair, and does not overwrite one the host has not read
//   * counts what it could not take, so a dropped find is visible
//
// WHAT IT DELIBERATELY DOES NOT DO: gate the cores' nonce counters. Those
// free-run inside miner_pipelined and pair the Nth result with the Nth input
// by construction. Gating a counter with the settle window is exactly the bug
// that produced 0x0108 and the reason the core was replaced.

module found_path #(
    parameter integer NUM_MINERS    = 2,
    parameter integer SETTLE_CYCLES = 4096,
    parameter integer FIFO_AW       = 3     // 8-deep
) (
    input  wire                      clk,

    // One-cycle pulse: a complete job has been snapshotted for the cores.
    input  wire                      commit,

    // One-cycle strobes and their nonces, straight from the cores.
    input  wire [NUM_MINERS-1:0]     found_in,
    input  wire [32*NUM_MINERS-1:0]  nonce_in_flat,

    // Two-phase handoff to the bus domain. ack_toggle flips once per nonce the
    // host has actually consumed; nonce_toggle flips once per nonce offered.
    input  wire                      ack_toggle,
    output reg                       nonce_toggle = 1'b0,
    output reg  [31:0]               nonce_latch  = 32'h0,

    // Telemetry.
    output wire                      report_ok,   // committed AND settled
    output wire [7:0]                lost_count,
    output wire [FIFO_AW:0]          fifo_count
);

    localparam integer FIFO_DEPTH = (1 << FIFO_AW);

    // ---------------------------------------------------------------
    // Settle window.
    //
    // have_job keeps it shut until the first commit ever. Without it the
    // counter reaches SETTLE_CYCLES shortly after configuration and starts
    // reporting finds against whatever the header registers power up holding
    // -- all zeroes, and every one of those finds a lie.
    // ---------------------------------------------------------------
    reg [15:0] settle_cnt = 16'd0;
    reg        have_job   = 1'b0;

    always @(posedge clk) begin
        if (commit) begin
            settle_cnt <= 16'd0;
            have_job   <= 1'b1;
        end else if (settle_cnt != SETTLE_CYCLES[15:0]) begin
            settle_cnt <= settle_cnt + 16'd1;
        end
    end

    assign report_ok = have_job & (settle_cnt == SETTLE_CYCLES[15:0]);

    // ---------------------------------------------------------------
    // Find collection.
    //
    // Both cores run off the same clock and the same THROUGHPUT counter, so
    // they can strobe on the same cycle. Scan for the first two; anything
    // beyond that would need NUM_MINERS > 2, which the BRAM budget does not
    // allow, and is counted as lost rather than assumed impossible.
    // ---------------------------------------------------------------
    integer    fpi;
    reg [2:0]  hits;
    reg [31:0] hit_first, hit_second;

    always @* begin
        hits       = 3'd0;
        hit_first  = 32'h0;
        hit_second = 32'h0;
        for (fpi = 0; fpi < NUM_MINERS; fpi = fpi + 1) begin
            if (found_in[fpi] & report_ok) begin
                if (hits == 3'd0)      hit_first  = nonce_in_flat[32*fpi +: 32];
                else if (hits == 3'd1) hit_second = nonce_in_flat[32*fpi +: 32];
                hits = hits + 3'd1;
            end
        end
    end

    // ---------------------------------------------------------------
    // FIFO + one-entry stash.
    //
    // The stash exists only to absorb the second of two simultaneous finds:
    // one entry is provably enough, because a core cannot produce another
    // result for THROUGHPUT cycles and the stash drains on the very next one.
    // ---------------------------------------------------------------
    reg [31:0]       fifo_mem [0:FIFO_DEPTH-1];
    reg [FIFO_AW:0]  wr_ptr = 0;
    reg [FIFO_AW:0]  rd_ptr = 0;
    wire [FIFO_AW:0] count  = wr_ptr - rd_ptr;
    wire             full   = (count == FIFO_DEPTH[FIFO_AW:0]);
    wire             empty  = (wr_ptr == rd_ptr);

    reg [7:0]  lost  = 8'h0;
    reg        pend_valid = 1'b0;
    reg [31:0] pend_nonce = 32'h0;

    assign fifo_count = count;
    assign lost_count = lost;

    reg        push_en;
    reg [31:0] push_dat;
    reg        stash_nxt_valid;
    reg [31:0] stash_nxt_dat;
    reg [2:0]  lost_inc;

    always @* begin
        push_en         = 1'b0;
        push_dat        = 32'h0;
        stash_nxt_valid = pend_valid;
        stash_nxt_dat   = pend_nonce;
        lost_inc        = 3'd0;

        if (pend_valid && !full) begin
            // The stash is older than anything arriving this cycle, so it goes
            // in first. The slot it frees can take one of this cycle's finds
            // in the same cycle.
            push_en         = 1'b1;
            push_dat        = pend_nonce;
            stash_nxt_valid = 1'b0;
            if (hits != 3'd0) begin
                stash_nxt_valid = 1'b1;
                stash_nxt_dat   = hit_first;
                lost_inc        = hits - 3'd1;
            end
        end else if (!pend_valid && (hits != 3'd0) && !full) begin
            push_en  = 1'b1;
            push_dat = hit_first;
            if (hits > 3'd1) begin
                stash_nxt_valid = 1'b1;
                stash_nxt_dat   = hit_second;
                lost_inc        = hits - 3'd2;
            end
        end else begin
            // Full, or full with the stash still occupied: nothing arriving
            // this cycle can be taken.
            lost_inc = hits;
        end
    end

    always @(posedge clk) begin
        if (commit) begin
            // FLUSH ON COMMIT. Anything queued was found against the PREVIOUS
            // header and cannot be a solution for the new one, so handing it
            // to the host would only produce a nonce it must reject. Dropping
            // it here keeps the invariant the host relies on: every nonce it
            // drains belongs to the job it most recently dispatched.
            //
            // Costs at most FIFO_DEPTH finds per job change, against a job
            // arriving every 5-10s -- nothing. Not counted as lost, because
            // these were not lost to congestion; they were deliberately
            // discarded as unusable, and conflating the two would make the
            // lost counter useless for spotting real congestion.
            // rd_ptr is reset in the handoff block below, which is its only
            // driver -- both see this same commit edge, so the two pointers
            // land back at 0 together and the FIFO reads empty.
            wr_ptr     <= 0;
            pend_valid <= 1'b0;
        end else begin
            if (push_en) begin
                fifo_mem[wr_ptr[FIFO_AW-1:0]] <= push_dat;
                wr_ptr <= wr_ptr + 1'b1;
            end
            pend_valid <= stash_nxt_valid;
            pend_nonce <= stash_nxt_dat;
        end

        if (lost_inc != 3'd0 && !commit) begin
            // Saturating. A loss counter that wraps reads as "no losses" once
            // every 256 of them, which is worse than not having one.
            if ({1'b0, lost} + {6'd0, lost_inc} >= 9'd255) lost <= 8'hFF;
            else                                           lost <= lost + {5'd0, lost_inc};
        end
    end

    // ---------------------------------------------------------------
    // Handoff to the bus domain.
    //
    // busy holds this side off until the host's ack lands, which is what makes
    // the handoff lossless: the latch is never overwritten while it still
    // holds a nonce nobody has read.
    // ---------------------------------------------------------------
    reg busy = 1'b0;

    (* ASYNC_REG = "TRUE" *) reg ack_s1 = 1'b0;
    reg ack_s2 = 1'b0, ack_s3 = 1'b0;
    wire ack_pulse = ack_s2 ^ ack_s3;

    always @(posedge clk) begin
        ack_s1 <= ack_toggle;
        ack_s2 <= ack_s1;
        ack_s3 <= ack_s2;

        if (ack_pulse)
            busy <= 1'b0;

        // Flush side owned by this block -- see the commit handling above.
        // busy is deliberately NOT cleared: if a nonce is already in the latch
        // the host may be mid-read of it, and yanking it would reintroduce the
        // torn-read this design just fixed. That one nonce belongs to the old
        // job and the host will reject it; one stale nonce per job change is
        // the price of not racing the bus.
        if (commit)
            rd_ptr <= 0;
        else if (!busy && !empty) begin
            nonce_latch  <= fifo_mem[rd_ptr[FIFO_AW-1:0]];
            rd_ptr       <= rd_ptr + 1'b1;
            nonce_toggle <= ~nonce_toggle;
            busy         <= 1'b1;
        end
    end

endmodule
