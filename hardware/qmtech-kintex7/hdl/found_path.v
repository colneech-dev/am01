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
    // Cycles between successive results from ONE core. The collector's
    // correctness depends on it -- see the stash-depth proof below -- so it is
    // a parameter rather than an assumption. Must match the cipher core's
    // THROUGHPUT; odo_gen emits 4.
    parameter integer THROUGHPUT    = 4,
    // EXPERIMENT ONLY -- see the guard below. Defaults to refusing.
    // NOTE: since the collector was widened this should never need setting.
    parameter integer ALLOW_LOSSY_MULTI_MINER = 0,
    parameter integer SETTLE_CYCLES = 4096,
    parameter integer FIFO_AW       = 3     // 8-deep
) (
    input  wire                      clk,

    // One-cycle pulse: a complete job has been snapshotted for the cores.
    input  wire                      commit,

    // FULL RESYNC, host-driven. Distinct from `commit`, which is a job change
    // and deliberately preserves `busy` (see the handoff block).
    //
    // THIS EXISTS BECAUSE ITS ABSENCE TOOK THE MINER DOWN FOR AN HOUR on
    // 2026-09-01. `busy` is set when a nonce is handed to the bus domain and
    // was clearable ONLY by the host's ack. If the host stops polling while a
    // nonce is still outstanding, `busy` latches with no ack ever coming, and
    // the handoff stalls forever: no further nonce can be loaded, the FIFO
    // fills, and every subsequent find increments `lost` until it saturates.
    //
    // NOTE THE TRIGGER IS MUNDANE. I first wrote this up as a SIGTERM landing
    // mid-transaction; that was wrong. The daemon's signal handling is
    // cooperative -- it sets a flag and the loops exit between iterations --
    // and the failing shutdown logged a clean exit. All it takes is a find
    // handed over after the host's last poll, which at ~15 finds/sec is a
    // window that is open essentially all the time. Any orderly shutdown can
    // do it.
    //
    // Nothing could clear it. This module had no reset input at all, so
    // `busy` took its initial value only at configuration; OP_SOFT_RESET
    // could not reach it, and `commit` deliberately does not touch it. The
    // observed symptom was a miner that reconnected, took jobs, dispatched
    // them, and found nothing -- surviving process restarts, and recovered
    // only by reloading the FPGA over JTAG.
    //
    // Safe to assert whenever the host has no read in flight, which is
    // exactly what daemon startup is.
    input  wire                      soft_reset,

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
    // All cores run off the same clock and the same THROUGHPUT counter, so
    // they can strobe on the same cycle. This scans ALL of them and holds the
    // overflow in a stash NUM_MINERS-1 deep, so a cycle in which every core
    // finds at once loses nothing.
    //
    // It used to scan for the first TWO and stash ONE, which made NUM_MINERS>2
    // lossy: with four cores, a cycle where three strobed together discarded
    // the third. Counted in `lost`, so visible, but at a 1-in-256 target that
    // is a real share thrown away.
    //
    // WHY NUM_MINERS-1 IS PROVABLY THE RIGHT DEPTH. Only one nonce can enter
    // the FIFO per cycle, so N simultaneous finds need N-1 held over. The
    // stash drains at one per cycle, i.e. in N-1 cycles. A core cannot
    // produce a second result for THROUGHPUT cycles, so the next batch cannot
    // arrive before then, and the stash is empty in time iff
    //
    //     NUM_MINERS - 1 <= THROUGHPUT - 1    i.e.   NUM_MINERS <= THROUGHPUT
    //
    // At NUM_MINERS=4, THROUGHPUT=4 that holds EXACTLY -- the stash empties on
    // the same cycle the next batch could arrive. The guard below checks that
    // inequality rather than a hardcoded 2, because the 2 was only ever a
    // proxy for it.
    // ---------------------------------------------------------------
    // Elaboration-time guard for the limit described above. Instantiating a
    // module that does not exist is the portable way to stop a build with a
    // name that says why -- $fatal in an initial block would fire only in
    // simulation, not synthesis.
    // ALLOW_LOSSY_MULTI_MINER remains an EXPERIMENT ESCAPE HATCH, and since
    // the collector was widened there is no longer a reason to set it. It is
    // kept only so that a deliberate over-subscription (NUM_MINERS >
    // THROUGHPUT) can still be built to measure something, and it is still
    // lossy when it is: past that ratio the stash cannot drain between
    // batches. DO NOT SET IT ON ANYTHING ANYONE MIGHT MINE ON.
    generate
        if (NUM_MINERS > THROUGHPUT && !ALLOW_LOSSY_MULTI_MINER)
        begin : g_too_many_miners
            FOUND_PATH_NUM_MINERS_EXCEEDS_THROUGHPUT_SEE_COMMENT bad();
        end
    endgenerate

    // Every core is scanned, not just the first two. hit[] is packed: hit[0]
    // is the lowest-numbered core that found this cycle, and `hits` counts
    // them.
    localparam integer STASH_DEPTH = (NUM_MINERS > 1) ? (NUM_MINERS - 1) : 1;

    integer    fpi;
    reg [3:0]  hits;
    reg [31:0] hit [0:NUM_MINERS-1];

    always @* begin
        hits = 4'd0;
        for (fpi = 0; fpi < NUM_MINERS; fpi = fpi + 1) hit[fpi] = 32'h0;
        for (fpi = 0; fpi < NUM_MINERS; fpi = fpi + 1) begin
            if (found_in[fpi] & report_ok) begin
                hit[hits] = nonce_in_flat[32*fpi +: 32];
                hits      = hits + 4'd1;
            end
        end
    end

    // ---------------------------------------------------------------
    // FIFO + one-entry stash.
    //
    // The stash absorbs everything that cannot enter the FIFO this cycle.
    // NUM_MINERS-1 entries is provably enough -- see the proof above the
    // collector. It drains one per cycle, oldest first.
    // ---------------------------------------------------------------
    reg [31:0]       fifo_mem [0:FIFO_DEPTH-1];
    reg [FIFO_AW:0]  wr_ptr = 0;
    reg [FIFO_AW:0]  rd_ptr = 0;
    wire [FIFO_AW:0] count  = wr_ptr - rd_ptr;
    wire             full   = (count == FIFO_DEPTH[FIFO_AW:0]);
    wire             empty  = (wr_ptr == rd_ptr);

    reg [7:0]  lost  = 8'h0;
    reg [31:0] stash [0:STASH_DEPTH-1];
    reg [3:0]  stash_n = 4'd0;

    assign fifo_count = count;
    assign lost_count = lost;

    reg        push_en;
    reg [31:0] push_dat;
    reg [31:0] stash_nxt [0:STASH_DEPTH-1];
    reg [3:0]  stash_nxt_n;
    reg [3:0]  first_new;
    reg [3:0]  lost_inc;
    integer    k;

    always @* begin
        push_en     = 1'b0;
        push_dat    = 32'h0;
        lost_inc    = 4'd0;
        first_new   = 4'd0;
        stash_nxt_n = stash_n;
        for (k = 0; k < STASH_DEPTH; k = k + 1) stash_nxt[k] = stash[k];

        if (!full) begin
            if (stash_n != 4'd0) begin
                // The stash is older than anything arriving this cycle, so it
                // goes in first and everything new queues behind it.
                push_en  = 1'b1;
                push_dat = stash[0];
                for (k = 0; k < STASH_DEPTH - 1; k = k + 1)
                    stash_nxt[k] = stash[k+1];
                stash_nxt_n = stash_n - 4'd1;
            end else if (hits != 4'd0) begin
                // Nothing held over: this cycle's first find goes straight in
                // and only the rest need stashing.
                push_en   = 1'b1;
                push_dat  = hit[0];
                first_new = 4'd1;
            end
        end
        // Everything this cycle that did not go straight into the FIFO queues
        // in the stash. Only what will not fit is lost -- which, per the proof
        // above, cannot happen while NUM_MINERS <= THROUGHPUT and the FIFO has
        // room.
        for (k = 0; k < NUM_MINERS; k = k + 1) begin
            if (k >= first_new && k < hits) begin
                if (stash_nxt_n < STASH_DEPTH[3:0]) begin
                    stash_nxt[stash_nxt_n] = hit[k];
                    stash_nxt_n            = stash_nxt_n + 4'd1;
                end else begin
                    lost_inc = lost_inc + 4'd1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (soft_reset) begin
            // Write side of the resync. Ordered first, same reasoning as the
            // handoff block: a resync that the normal path can override in
            // the same cycle is not one you can rely on.
            //
            // `lost` is cleared too. It is a congestion counter, and carrying
            // a saturated 255 across a deliberate resync would mask the next
            // real problem behind the last one. The host should READ it
            // before resetting -- am01-uartd and the miner both do, and it is
            // the single most useful number for spotting that finds are being
            // dropped on the floor.
            wr_ptr     <= 0;
            stash_n    <= 4'd0;
            lost       <= 8'h0;
        end else if (commit) begin
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
            stash_n    <= 4'd0;
        end else begin
            if (push_en) begin
                fifo_mem[wr_ptr[FIFO_AW-1:0]] <= push_dat;
                wr_ptr <= wr_ptr + 1'b1;
            end
            stash_n <= stash_nxt_n;
            for (k = 0; k < STASH_DEPTH; k = k + 1) stash[k] <= stash_nxt[k];
        end

        if (lost_inc != 4'd0 && !commit && !soft_reset) begin
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

        if (soft_reset) begin
            // The whole handoff, back to its configuration state. Ordered
            // FIRST so it wins over every case below -- a resync that could
            // be overridden by the same cycle's normal path would be a
            // resync you cannot rely on.
            busy         <= 1'b0;
            rd_ptr       <= 0;
            nonce_latch  <= 32'h0;
            // nonce_toggle is deliberately LEFT ALONE. It is a two-phase
            // handshake: forcing its level would either look like a spurious
            // new nonce to the bus domain or desynchronise the two sides.
            // Clearing `busy` is what unblocks this; the toggle takes care of
            // itself on the next real find.
        end
        else if (ack_pulse)
            busy <= 1'b0;

        // Flush side owned by this block -- see the commit handling above.
        // busy is deliberately NOT cleared: if a nonce is already in the latch
        // the host may be mid-read of it, and yanking it would reintroduce the
        // torn-read this design just fixed. That one nonce belongs to the old
        // job and the host will reject it; one stale nonce per job change is
        // the price of not racing the bus.
        if (soft_reset) begin
            /* handled above */
        end
        else if (commit)
            rd_ptr <= 0;
        else if (!busy && !empty) begin
            nonce_latch  <= fifo_mem[rd_ptr[FIFO_AW-1:0]];
            rd_ptr       <= rd_ptr + 1'b1;
            nonce_toggle <= ~nonce_toggle;
            busy         <= 1'b1;
        end
    end

endmodule
