//////////////////////////////////////////////////////////////////////////////////
/*
 *  AtomMiner AM01 -- QMTECH Kintex-7 + Raspberry Pi CM4 variant, design proposal
 *
 *  Copyright 2015-2022 AtomMiner <atom@atomminer.com>
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation; either version 3 of the License, or (at your option)
 * any later version. If not, see <http://www.gnu.org/licenses/>.
 *
 */
//////////////////////////////////////////////////////////////////////////////////
//
// odocrypt_gpio_wrapper
//
// Replacement for exmaples/odocrypt/fpga/src/hdl/usb3_interface.v +
// usb3_sm_v3.v on the QMTECH XC7K325T + Raspberry Pi CM4 variant (see
// ../README.md). A Raspberry Pi CM4 plugged into the QMTECH board's CM4
// socket drives header/target words and reads the golden nonce over 24
// general-purpose GPIO lines using a simple 4-phase parallel bus, instead
// of the FX3's DQ-bus/USB link or the Zynq variant's on-chip AXI4-Lite.
// odo_block_data, host_break_sm and miner_top (and everything below
// them) are reused completely unmodified from hdl/odocrypt/ (a copy of
// exmaples/odocrypt/fpga/src/hdl/ kept in sync with the current OdoCrypt
// epoch -- see hdl/odocrypt/NOTICE).
//
// STATUS: reference skeleton for a hardware proposal, not verified/timed
// silicon-ready RTL. See "What's still needed before this is real
// hardware" in ../README.md -- in particular gpio_wr_n/gpio_rd_n/
// gpio_addr/gpio_data are asynchronous inputs from the CM4 (no shared
// clock), synchronized here with plain multi-flop synchronizers that
// still need ASYNC_REG + timing-exception signoff before tape-out.
//
// Register map (see ../README.md): 16-bit-per-beat, ADDR-selected.
//
`timescale 1ns / 1ps

module odocrypt_gpio_wrapper #(
    // Number of parallel hash-core instances. BRAM-bound on this chip:
    // one instance = 420 RAMB18 of the XC7K325T's 890 (measured), so 2
    // fills the budget at 94% and 3 does not fit. Set to 1 to get the
    // original single-core behaviour back. See ../README.md
    // "Expected hashrate" for the derivation.
    parameter integer NUM_MINERS = 2,

    // OdoCrypt epoch seed that hdl/odocrypt/encrypt.v was generated for,
    // read back by the host at SEED_LO/SEED_HI as bitstream_epoch.
    //
    // The default is the real value rather than 0 so it is correct without
    // either build flow having to pass a generic. It MUST match the seed
    // stamped in encrypt.v's header -- tools/check-epoch.sh enforces that and
    // flags staleness against the current date. Update both together.
    parameter [31:0] ODO_SEED = 32'd1787616000
) (
    // ---------------------------------------------------------------
    // Bus clock domain -- the board's onboard 50MHz crystal
    // (sys_clk_50m in the .xdc), or an MMCM-derived clock from it.
    // ---------------------------------------------------------------
    input  wire        bus_clk,
    input  wire        bus_rst_n,

    // ---------------------------------------------------------------
    // GPIO parallel bus to the CM4 socket. Asynchronous to bus_clk --
    // driven either by bit-banged GPIO or the BCM2711 SMI peripheral.
    // ---------------------------------------------------------------
    inout  wire [15:0] gpio_data,
    input  wire [3:0]  gpio_addr,
    input  wire        gpio_wr_n,   // active low
    input  wire        gpio_rd_n,   // active low
    output reg          gpio_ready,
    output wire        gpio_irq,    // level, asserted while a nonce is pending

    // ---------------------------------------------------------------
    // Hash-core clock domain. clk_h is whatever feeds miner_top today
    // (an MMCM output derived from the 50MHz crystal, same role
    // artix200_v3_clocking plays on the stock AM01).
    // ---------------------------------------------------------------
    input  wire        clk_h
);

    // -----------------------------------------------------------------
    // Register map
    // -----------------------------------------------------------------
    localparam [3:0] ADDR_VERSION    = 4'h0;
    localparam [3:0] ADDR_CTRL       = 4'h1;
    localparam [3:0] ADDR_STATUS     = 4'h2;
    localparam [3:0] ADDR_NONCE_LO   = 4'h3;
    localparam [3:0] ADDR_NONCE_HI   = 4'h4;
    localparam [3:0] ADDR_HEADER_LO  = 4'h5;
    localparam [3:0] ADDR_HEADER_HI  = 4'h6;
    localparam [3:0] ADDR_TARGET_LO  = 4'h7;
    localparam [3:0] ADDR_TARGET_HI  = 4'h8;
    // Read-only: the OdoCrypt epoch seed encrypt.v was generated for. The
    // daemon reads this back as bitstream_epoch and compares it against the
    // pool's job epoch; without it a stale bitstream mines rejects silently.
    localparam [3:0] ADDR_SEED_LO    = 4'h9;
    localparam [3:0] ADDR_SEED_HI    = 4'hA;

    // v1.1 adds SEED_LO/SEED_HI. The daemon treats a VERSION below this as
    // "seed unreadable" rather than misreading 0 as a real epoch.
    localparam [15:0] VERSION = 16'h0101;

    // Request opcodes carried across the bus_clk -> clk_h handshake.
    localparam [1:0] OP_HEADER_WORD = 2'b00;
    localparam [1:0] OP_TARGET_WORD = 2'b01;
    localparam [1:0] OP_HOST_BREAK  = 2'b10;
    localparam [1:0] OP_SOFT_RESET  = 2'b11;

    // =====================================================================
    // Synchronize the async CM4-driven bus into bus_clk. ADDR/DATA are
    // sampled only once WR_N/RD_N has been seen low for two consecutive
    // bus_clk cycles, so they're required to be stable before the strobe
    // asserts -- standard practice for a source-synchronous-ish bus with
    // no shared clock.
    // =====================================================================
    // ASYNC_REG on the first flop of each chain: tells P&R to place it
    // close to whatever feeds it and prioritize it for MTBF, since it's
    // the one actually catching an asynchronous input mid-transition.
    // Paired with the set_clock_groups -asynchronous in the .xdc between
    // sys_clk_50m and clk_h -- that tells STA these two clocks aren't
    // meant to be timed against each other; this tells P&R the flops
    // that assumption depends on need real metastability handling.
    // wr_sync/rd_sync are stored ACTIVE-HIGH (inverted from the raw
    // active-low gpio_wr_n/gpio_rd_n) purely so their idle/reset state is
    // all-zero instead of all-one. That is not cosmetic: a reset-to-1
    // register synthesizes to FDSE ("set" primitive) instead of FDRE
    // ("reset" primitive), and FDRE/FDSE turn out to be JUST as
    // half-slice-incompatible as the sync/async split above -- confirmed
    // by hitting a second real 'control-set contention' FASM error, on
    // this exact register, after already eliminating FDCE/FDPE. Same
    // fix category, one bit of polarity instead of a sensitivity list.
    // Functionally identical either way -- see wr_active/rd_active and
    // the S_WRITE/S_READ release checks below, which un-invert as needed.
    (* ASYNC_REG = "TRUE" *) reg [2:0] wr_sync, rd_sync;
    (* ASYNC_REG = "TRUE" *) reg [3:0] addr_sync0;
    reg [3:0] addr_sync1;
    (* ASYNC_REG = "TRUE" *) reg [15:0] data_in_sync0;
    reg [15:0] data_in_sync1;

    // Synchronous reset deliberately, not async: bus_rst_n is already
    // deasserted synchronously (see am01_qmtech_top.v's rst_stretch
    // counter), so nothing here needs true async behaviour. Kept sync
    // for a real, measured reason -- see openxc7/README.md "Why every
    // reset in this file is synchronous": Xilinx 7-series async-set/
    // reset FFs (FDCE/FDPE) route through the same half-slice control
    // network as the sync ones (FDRE/FDSE), and nextpnr-xilinx's placer
    // does not reliably keep the two families apart -- confirmed via a
    // real 'control-set contention' FASM error on 2/2 random seeds
    // before this fix. Vivado handles the mix fine; this is an openXC7
    // portability fix, not a correctness bug this file ever had.
    always @(posedge bus_clk) begin
        if (!bus_rst_n) begin
            wr_sync <= 3'b000;
            rd_sync <= 3'b000;
        end else begin
            wr_sync <= {wr_sync[1:0], ~gpio_wr_n};
            rd_sync <= {rd_sync[1:0], ~gpio_rd_n};
        end
    end

    always @(posedge bus_clk) begin
        addr_sync0 <= gpio_addr;
        addr_sync1 <= addr_sync0;
        data_in_sync0 <= gpio_data;
        data_in_sync1 <= data_in_sync0;
    end

    wire wr_active = wr_sync[2] & wr_sync[1]; // debounced write request
    wire rd_active = rd_sync[2] & rd_sync[1]; // debounced read request

    // =====================================================================
    // bus_clk -> clk_h request/ack handshake (same two-phase toggle
    // synchronizer pattern as hardware/zynq/hdl/odocrypt_axi_wrapper.v).
    // req_toggle_bus only flips once the previous request has been
    // ack'd, enforced below by holding the bus state machine (and thus
    // GPIO_READY) until ack_pulse_bus arrives, so req_op/req_data are
    // guaranteed stable for the whole round trip.
    // =====================================================================
    reg        req_toggle_bus;
    reg [1:0]  req_op_bus;
    reg [31:0] req_data_bus;

    (* ASYNC_REG = "TRUE" *) reg req_sync1_h;
    reg req_sync2_h, req_sync3_h;
    reg ack_toggle_h;
    (* ASYNC_REG = "TRUE" *) reg ack_sync1_bus;
    reg ack_sync2_bus, ack_sync3_bus;

    wire req_pulse_h   = req_sync2_h ^ req_sync3_h;
    wire ack_pulse_bus = ack_sync2_bus ^ ack_sync3_bus;

    always @(posedge clk_h) begin
        req_sync1_h <= req_toggle_bus;
        req_sync2_h <= req_sync1_h;
        req_sync3_h <= req_sync2_h;
        if (req_pulse_h)
            ack_toggle_h <= ~ack_toggle_h;
    end

    always @(posedge bus_clk) begin
        ack_sync1_bus <= ack_toggle_h;
        ack_sync2_bus <= ack_sync1_bus;
        ack_sync3_bus <= ack_sync2_bus;
    end

    // =====================================================================
    // Bus-side state machine: 4-phase interlocked handshake, one
    // register access at a time.
    // =====================================================================
    localparam S_IDLE  = 2'd0,
               S_WRITE = 2'd1,
               S_READ  = 2'd2;

    reg [1:0]  bus_state;
    reg [3:0]  addr_latched;
    reg [15:0] wdata_latched;
    reg [15:0] header_lo_stage, target_lo_stage;
    reg        request_issued;
    reg [15:0] rdata_reg;
    reg        gpio_data_oe;

    // Status/nonce values, already synchronized into bus_clk further down.
    wire        hash_active_bus;
    wire        nonce_valid_bus;
    wire [31:0] golden_nonce_bus;
    reg         nonce_valid_clear_pulse;

    // Synchronous reset deliberately -- see the sync-vs-async note above
    // wr_sync/rd_sync's always block; same reasoning applies here.
    always @(posedge bus_clk) begin
        if (!bus_rst_n) begin
            bus_state       <= S_IDLE;
            gpio_ready      <= 1'b0;
            gpio_data_oe    <= 1'b0;
            request_issued  <= 1'b0;
            // NOTE: req_toggle_bus is deliberately NOT reset here.
            //
            // It is a toggle, not a state -- only its TRANSITIONS carry meaning,
            // and the clk_h receiver detects them as req_sync2_h ^ req_sync3_h.
            // Forcing it to 0 on reset creates an edge if it happened to be 1,
            // which fires one spurious request on the clk_h side carrying stale
            // req_op_bus/req_data_bus. Because odo_block_data is a plain 19-deep
            // shift register with no word counter and no position reset, a single
            // extra get_block_pulse_h shifts the entire header by one 32-bit word
            // -- after which the miner runs normally and every result is wrong,
            // with no recovery path (OP_SOFT_RESET clears the word counters but
            // not the shift-register position).
            //
            // The clk_h synchroniser has no reset of its own, so leaving this
            // undisturbed is what keeps the two sides consistent across a bus
            // reset. Do not "tidy" this into the reset list.
            header_lo_stage <= 16'h0;
            target_lo_stage <= 16'h0;
            nonce_valid_clear_pulse <= 1'b0;
        end else begin
            nonce_valid_clear_pulse <= 1'b0;

            case (bus_state)
                S_IDLE: begin
                    gpio_ready   <= 1'b0;
                    gpio_data_oe <= 1'b0;
                    request_issued <= 1'b0;
                    if (wr_active) begin
                        addr_latched  <= addr_sync1;
                        wdata_latched <= data_in_sync1;
                        bus_state     <= S_WRITE;
                    end else if (rd_active) begin
                        addr_latched <= addr_sync1;
                        bus_state    <= S_READ;
                    end
                end

                S_WRITE: begin
                    case (addr_latched)
                        ADDR_CTRL: begin
                            if (!request_issued) begin
                                req_op_bus     <= wdata_latched[1] ? OP_HOST_BREAK : OP_SOFT_RESET;
                                req_data_bus   <= {16'h0, wdata_latched};
                                req_toggle_bus <= ~req_toggle_bus;
                                request_issued <= 1'b1;
                            end else if (ack_pulse_bus) begin
                                gpio_ready <= 1'b1;
                            end
                        end
                        ADDR_HEADER_LO: begin
                            header_lo_stage <= wdata_latched;
                            gpio_ready      <= 1'b1; // staging only, no clk_h side effect
                        end
                        ADDR_HEADER_HI: begin
                            if (!request_issued) begin
                                req_op_bus     <= OP_HEADER_WORD;
                                req_data_bus   <= {wdata_latched, header_lo_stage};
                                req_toggle_bus <= ~req_toggle_bus;
                                request_issued <= 1'b1;
                            end else if (ack_pulse_bus) begin
                                gpio_ready <= 1'b1;
                            end
                        end
                        ADDR_TARGET_LO: begin
                            target_lo_stage <= wdata_latched;
                            gpio_ready      <= 1'b1; // staging only
                        end
                        ADDR_TARGET_HI: begin
                            if (!request_issued) begin
                                req_op_bus     <= OP_TARGET_WORD;
                                req_data_bus   <= {wdata_latched, target_lo_stage};
                                req_toggle_bus <= ~req_toggle_bus;
                                request_issued <= 1'b1;
                            end else if (ack_pulse_bus) begin
                                gpio_ready <= 1'b1;
                            end
                        end
                        default: begin
                            // Write to a read-only/unmapped address: ack, no effect.
                            gpio_ready <= 1'b1;
                        end
                    endcase

                    if (gpio_ready && !wr_sync[2]) begin
                        // CM4 released WR_N after seeing READY (wr_sync is
                        // active-high, so "released" is 0, not 1 -- see
                        // its declaration comment).
                        gpio_ready <= 1'b0;
                        bus_state  <= S_IDLE;
                    end
                end

                S_READ: begin
                    case (addr_latched)
                        ADDR_VERSION:  rdata_reg <= VERSION;
                        ADDR_STATUS:   rdata_reg <= {14'h0, nonce_valid_bus, hash_active_bus};
                        ADDR_NONCE_LO: rdata_reg <= golden_nonce_bus[15:0];
                        ADDR_NONCE_HI: begin
                            rdata_reg <= golden_nonce_bus[31:16];
                            nonce_valid_clear_pulse <= 1'b1; // clears NONCE_VALID / irq
                        end
                        ADDR_SEED_LO:  rdata_reg <= ODO_SEED[15:0];
                        ADDR_SEED_HI:  rdata_reg <= ODO_SEED[31:16];
                        default: rdata_reg <= 16'h0;
                    endcase
                    gpio_data_oe <= 1'b1;
                    gpio_ready   <= 1'b1;

                    if (gpio_ready && !rd_sync[2]) begin
                        // CM4 released RD_N after seeing READY (rd_sync is
                        // active-high -- see wr_sync's declaration comment).
                        gpio_ready   <= 1'b0;
                        gpio_data_oe <= 1'b0;
                        bus_state    <= S_IDLE;
                    end
                end

                default: bus_state <= S_IDLE;
            endcase
        end
    end

    assign gpio_data = gpio_data_oe ? rdata_reg : 16'bz;

    // =====================================================================
    // Hash-core (clk_h) domain: decode the request into the same pulses
    // odo_block_data / host_break_sm expect, and drive miner_top exactly
    // like exmaples/odocrypt/fpga/src/hdl/atomminer_odocrypt.v did. This
    // section mirrors hardware/zynq/hdl/odocrypt_axi_wrapper.v verbatim.
    // =====================================================================
    reg [31:0] data_from_host_h;
    reg        get_block_pulse_h;
    reg        get_target_pulse_h;
    reg        host_break_pulse_h;

    reg [4:0]  header_word_cnt_h; // 0..18, 19 words total
    reg [3:0]  target_word_cnt_h; // 0..7,  8 words total
    reg        start_hash_h;

    always @(posedge clk_h) begin
        get_block_pulse_h  <= 1'b0;
        get_target_pulse_h <= 1'b0;
        host_break_pulse_h <= 1'b0;

        if (req_pulse_h) begin
            data_from_host_h <= req_data_bus;
            case (req_op_bus)
                OP_HEADER_WORD: begin
                    get_block_pulse_h <= 1'b1;
                    header_word_cnt_h <= header_word_cnt_h + 1'b1;
                end
                OP_TARGET_WORD: begin
                    get_target_pulse_h <= 1'b1;
                    target_word_cnt_h  <= target_word_cnt_h + 1'b1;
                    if (target_word_cnt_h == 4'd7)
                        start_hash_h <= 1'b1; // 8th (last) target word arms the core
                end
                OP_HOST_BREAK: begin
                    host_break_pulse_h <= 1'b1;
                end
                OP_SOFT_RESET: begin
                    header_word_cnt_h <= 5'h0;
                    target_word_cnt_h <= 4'h0;
                    start_hash_h      <= 1'b0;
                end
            endcase
        end

        if (host_break_debounced)
            start_hash_h <= 1'b0;
    end

    wire [607:0] header;
    wire [255:0] target;
    wire         host_break_debounced; // = host_break_sm's sha_host_break output
    wire         ticket2moon;
    wire [31:0]  golden_nonce_h;

    odo_block_data odo_block_data_inst (
        .clk_h            (clk_h),
        .data_from_host_in(data_from_host_h),
        .get_midstate_in  (1'b0), // GPIO side collapses midstate/block into one FIFO
        .get_block_in     (get_block_pulse_h),
        .get_target_in    (get_target_pulse_h),
        .header           (header),
        .target           (target)
    );

    host_break_sm host_break_sm_inst (
        .clk_h         (clk_h),
        .host_break    (host_break_pulse_h),
        .ticket2moon   (ticket2moon_i),   // gated -- see below, NOT raw
        .hash_cmplt    (1'b0),
        .sha_host_break(host_break_debounced)
    );

    // -----------------------------------------------------------------
    // Hash-core bank. NUM_MINERS instances share one work item, each
    // sweeping its own slice of the 32-bit nonce space via NONCE_BASE.
    //
    // Why more than one: a single instance uses 420 RAMB18 of this
    // chip's 890 (measured -- they are OdoCrypt's large S-boxes), i.e.
    // it leaves nearly half the block RAM idle while using only ~9% of
    // the logic. Total hashrate here is BRAM-bound at roughly
    // 0.5 x Fmax, and one instance only reaches half of that. See
    // ../README.md "Expected hashrate".
    //
    // NUM_MINERS=2 fills the BRAM budget. MEASURED by walking the
    // synthesised hierarchy (not estimated): 1 instance = 420 RAMB18
    // (47.2% of the XC7K325T's 890), 2 instances = 840 (94.4%) -- fits,
    // with 50 RAMB18 spare. 3 would need 1260 and cannot fit. Do not
    // raise this without re-measuring.
    // -----------------------------------------------------------------
    wire [NUM_MINERS-1:0] t2m_arr;
    wire [31:0]           nonce_arr [0:NUM_MINERS-1];

    genvar gi;
    generate
        for (gi = 0; gi < NUM_MINERS; gi = gi + 1) begin : g_miner
            miner_top #(
                // Even split of the nonce space: instance gi sweeps
                // [gi*span, (gi+1)*span). For NUM_MINERS=2 that is
                // 0x00000000 and 0x80000000.
                .NONCE_BASE(gi * ((32'hFFFFFFFF / NUM_MINERS) + 32'h1))
            ) miner_top_inst (
                .osc_clk    (clk_h),
                .header     (header),
                .target     (target),
                .start_hash (start_hash_h),
                .ticket2moon(t2m_arr[gi]),
                .nonce      (nonce_arr[gi])
            );
        end
    endgenerate

    // Any instance finding a solution raises the shared ticket2moon.
    assign ticket2moon = |t2m_arr;

    // Pick the winning instance's nonce. If two hit on the same cycle
    // the lower index wins and the other is lost -- the same
    // single-latch limitation ../README.md already documents for
    // back-to-back solves, not a new one introduced by the bank.
    integer mi;
    reg [31:0] golden_nonce_mux;
    always @* begin
        golden_nonce_mux = nonce_arr[0];
        for (mi = NUM_MINERS - 1; mi >= 0; mi = mi - 1)
            if (t2m_arr[mi]) golden_nonce_mux = nonce_arr[mi];
    end
    assign golden_nonce_h = golden_nonce_mux;

    // -----------------------------------------------------------------
    // ticket2moon qualification -- must match atomminer_odocrypt.v.
    //
    // miner_top's `ticket2moon` is the RAW combinational "hash meets
    // target" comparator coming out of odo_keccak (miner.v ends with
    // `assign ticket2moon = res;`), and miner.v captures its own `nonce`
    // only under `has_res & start_hash & nonce_out_go`. The reference top
    // level never consumes that raw signal: it builds a gated, registered
    // copy and feeds *that* to both host_break_sm and its result path
    // (atomminer_odocrypt.v, lines ~158 / ~176 / ~221):
    //
    //     always @ (posedge clk_h)
    //         ticket2moon_i <= ticket2moon & nonce_out_go_top;
    //
    // An earlier revision of this wrapper used the raw signal in both
    // places while claiming in comments to mirror that file. This restores
    // the reference's behaviour.
    //
    // HONESTY NOTE ON WHY: this is reference fidelity / defence in depth,
    // NOT a demonstrated bug fix. Two failure modes were hypothesised for
    // the raw signal -- a spurious assertion during pipeline warm-up, and
    // a multi-cycle level breaking the CDC toggle below. **Neither
    // reproduced in simulation.** Driving miner_top with target=all-ones
    // (so every hash "wins") from reset, iverilog measured:
    //
    //     during warm-up (206 cycles): ticket2moon === 1'b0 for all of
    //         them; 0 cycles at 1, and 0 cycles at X (so the 0 is a real
    //         0, not an X that `if (ticket2moon)` silently read as false)
    //     after warm-up: 48 assertions over ~200 cycles -- one per
    //         THROUGHPUT(4)-cycle result slot -- each exactly 1 cycle
    //         long, never 2+ consecutive
    //
    // i.e. in that test the raw signal already behaved as a clean, warm-up
    // -respecting one-shot, and this gating is a measured no-op. It is
    // kept because the reference authors put it there and this file claims
    // to mirror them, and because it is provably unable to do harm (see
    // the 205-vs-204 note below). Reverting it would also be defensible;
    // what is NOT defensible is leaving the earlier commit message's
    // claim that it "could stall the miner" standing, since the evidence
    // does not support that.
    //
    // cou_deltanonce_top counts every clk_h cycle up to 8'hcd (205), which
    // is the same warm-up interval miner.v expresses internally as 6'h33
    // (51) counts of `advance` (51 x THROUGHPUT(4) = 204). Kept byte-for-
    // byte identical to the reference rather than re-derived.
    //
    // That 205-vs-204 relationship is why this gate cannot lose a real
    // solution: miner.v does not validly capture a nonce until its own
    // 204-cycle qualifier is met, so a nonce suppressed by opening this
    // gate one cycle later was never a nonce miner.v would have reported.
    // -----------------------------------------------------------------
    reg [7:0] cou_deltanonce_top = 8'h0;
    reg       nonce_out_go_top   = 1'b0;
    reg       ticket2moon_i      = 1'b0;

    always @(posedge clk_h)
        if (~start_hash_h) cou_deltanonce_top <= 8'h0;
        else               cou_deltanonce_top <= cou_deltanonce_top + 1'b1;

    always @(posedge clk_h)
        if (~start_hash_h)                    nonce_out_go_top <= 1'b0;
        else if (cou_deltanonce_top == 8'hcd) nonce_out_go_top <= 1'b1;

    always @(posedge clk_h)
        ticket2moon_i <= ticket2moon & nonce_out_go_top;

    // One-shot on top of the reference's gating. This wrapper -- unlike
    // the reference, which ships results over FX3 -- hands the nonce
    // across a clock domain using the two-phase toggle below. If
    // ticket2moon_i were ever high for 2+ consecutive cycles, flipping the
    // toggle on the level would flip it once per cycle, and the bus-side
    // 2-flop synchroniser would be sampling a signal changing faster than
    // it can track (golden_nonce_latch_h moving while captured = a torn
    // nonce). Measured longest run in simulation was exactly 1 cycle, so
    // today this is equivalent to the level-triggered version -- it makes
    // the one-shot assumption explicit and enforced rather than relying on
    // odo_keccak's comparator continuing to behave that way.
    reg  ticket2moon_i_d = 1'b0;
    always @(posedge clk_h) ticket2moon_i_d <= ticket2moon_i;
    wire ticket2moon_rise = ticket2moon_i & ~ticket2moon_i_d;

    // -----------------------------------------------------------------
    // Result latch + clk_h -> bus_clk status/nonce synchronization.
    // Same "accepted race on a status/telemetry register" simplification
    // as the Zynq wrapper -- see its comments for the rationale.
    // -----------------------------------------------------------------
    reg        nonce_toggle_h;
    reg [31:0] golden_nonce_latch_h;

    always @(posedge clk_h) begin
        if (ticket2moon_rise) begin
            golden_nonce_latch_h <= golden_nonce_h;
            nonce_toggle_h       <= ~nonce_toggle_h;
        end
    end

    (* ASYNC_REG = "TRUE" *) reg nonce_sync1_bus;
    reg nonce_sync2_bus, nonce_sync3_bus;
    (* ASYNC_REG = "TRUE" *) reg hash_active_sync1_bus;
    reg hash_active_sync2_bus;
    reg [31:0] golden_nonce_reg;
    reg        nonce_valid_reg;

    wire nonce_new_pulse_bus = nonce_sync2_bus ^ nonce_sync3_bus;

    // Synchronous reset deliberately -- see the sync-vs-async note above
    // wr_sync/rd_sync's always block; same reasoning applies here.
    always @(posedge bus_clk) begin
        if (!bus_rst_n) begin
            nonce_sync1_bus <= 1'b0;
            nonce_sync2_bus <= 1'b0;
            nonce_sync3_bus <= 1'b0;
            hash_active_sync1_bus <= 1'b0;
            hash_active_sync2_bus <= 1'b0;
            nonce_valid_reg <= 1'b0;
            golden_nonce_reg <= 32'h0;
        end else begin
            nonce_sync1_bus <= nonce_toggle_h;
            nonce_sync2_bus <= nonce_sync1_bus;
            nonce_sync3_bus <= nonce_sync2_bus;

            hash_active_sync1_bus <= start_hash_h;
            hash_active_sync2_bus <= hash_active_sync1_bus;

            if (nonce_new_pulse_bus) begin
                golden_nonce_reg <= golden_nonce_latch_h;
                nonce_valid_reg  <= 1'b1;
            end else if (nonce_valid_clear_pulse) begin
                nonce_valid_reg  <= 1'b0;
            end
        end
    end

    assign hash_active_bus  = hash_active_sync2_bus;
    assign nonce_valid_bus  = nonce_valid_reg;
    assign golden_nonce_bus = golden_nonce_reg;
    assign gpio_irq         = nonce_valid_reg;

endmodule
