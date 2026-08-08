//////////////////////////////////////////////////////////////////////////////////
/*
 *  AtomMiner AM01 -- Zynq (FPGA+ARM) variant, design proposal
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
// odocrypt_axi_wrapper
//
// Drop-in replacement for exmaples/odocrypt/fpga/src/hdl/usb3_interface.v +
// usb3_sm_v3.v on a Zynq-based AM01 variant (see ../README.md). Instead of
// serializing header/target words across the DQ[31:0] bus to/from a Cypress
// FX3 chip, an ARM core on the Zynq PS writes them directly over on-chip
// AXI4-Lite. odo_block_data, host_break_sm and miner_top (and everything
// below them: encrypt.v, keccak800.v, miner.v) are reused completely
// unmodified from exmaples/odocrypt/fpga/src/hdl/.
//
// STATUS: reference skeleton for a hardware proposal, not verified/timed
// silicon-ready RTL. See "What's still needed before this is real hardware"
// in ../README.md before treating this as production logic -- in
// particular the CDC scheme below uses plain 2-flop synchronizers, which is
// the standard technique for single toggle/level bits but still needs a
// real CDC-aware timing signoff (set_property ASYNC_REG, false-path /
// max-delay constraints on the synchronizer flops, etc.) before tape-out.
//
// Register map (byte offsets, 32-bit registers): see ../README.md.
//
`timescale 1ns / 1ps

module odocrypt_axi_wrapper #(
    parameter integer C_S_AXI_ADDR_WIDTH = 6,   // 0x00 .. 0x14
    parameter integer C_S_AXI_DATA_WIDTH = 32
)
(
    // ---------------------------------------------------------------
    // AXI4-Lite slave interface -- hang this off the Zynq PS's
    // M_AXI_GP0/GP1 (or an AXI interconnect) in the Vivado block design.
    // ---------------------------------------------------------------
    input  wire                              s_axi_aclk,
    input  wire                              s_axi_aresetn,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  wire                              s_axi_awvalid,
    output reg                               s_axi_awready,

    input  wire [C_S_AXI_DATA_WIDTH-1:0]     s_axi_wdata,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  wire                              s_axi_wvalid,
    output reg                               s_axi_wready,

    output reg  [1:0]                        s_axi_bresp,
    output reg                               s_axi_bvalid,
    input  wire                              s_axi_bready,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
    input  wire                              s_axi_arvalid,
    output reg                               s_axi_arready,

    output reg  [C_S_AXI_DATA_WIDTH-1:0]     s_axi_rdata,
    output reg  [1:0]                        s_axi_rresp,
    output reg                               s_axi_rvalid,
    input  wire                              s_axi_rready,

    // ---------------------------------------------------------------
    // Hash-core clock domain. clk_h is whatever feeds miner_top today --
    // a PS-generated FCLKn, or an external oscillator through a PL MMCM,
    // per ../README.md's clocking section.
    // ---------------------------------------------------------------
    input  wire                              clk_h,

    // Level interrupt into the Zynq PS's GIC (e.g. via IRQ_F2P). Asserted
    // when a golden nonce is ready, deasserted when firmware reads
    // GOLDEN_NONCE.
    output wire                              irq
);

    // -----------------------------------------------------------------
    // Register map
    // -----------------------------------------------------------------
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_VERSION = 6'h00;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CTRL    = 6'h04;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_STATUS  = 6'h08;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_NONCE   = 6'h0C;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_HEADER  = 6'h10;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_TARGET  = 6'h14;

    localparam [31:0] VERSION = 32'h0001_0000; // v1.0 of this register interface

    // Request opcodes carried across the AXI -> clk_h handshake below.
    localparam [1:0] OP_HEADER_WORD = 2'b00;
    localparam [1:0] OP_TARGET_WORD = 2'b01;
    localparam [1:0] OP_HOST_BREAK  = 2'b10;
    localparam [1:0] OP_SOFT_RESET  = 2'b11;

    // =====================================================================
    // AXI4-Lite write channel (single outstanding transaction)
    // =====================================================================
    reg [C_S_AXI_ADDR_WIDTH-1:0] awaddr_r;
    reg                          write_pending;   // AW+W captured, waiting on BVALID
    reg                          write_needs_ack; // this write must wait for the clk_h handshake

    // Toggle/data sent into the clk_h domain. Held stable from the moment
    // req_toggle_axi flips until ack_toggle_h (synchronized back as
    // ack_sync2_axi) confirms the clk_h side consumed it -- BVALID is held
    // off for the whole round trip, so the AXI master naturally can't
    // issue a new request before this one is retired.
    reg                          req_toggle_axi;
    reg [1:0]                    req_op_axi;
    reg [31:0]                   req_data_axi;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready   <= 1'b0;
            s_axi_wready    <= 1'b0;
            s_axi_bvalid    <= 1'b0;
            s_axi_bresp     <= 2'b00;
            write_pending   <= 1'b0;
            write_needs_ack <= 1'b0;
            req_toggle_axi  <= 1'b0;
        end else begin
            // Accept a new write address+data once no transaction is in flight.
            if (!write_pending && s_axi_awvalid && s_axi_wvalid &&
                !s_axi_awready && !s_axi_wready) begin
                s_axi_awready   <= 1'b1;
                s_axi_wready    <= 1'b1;
                awaddr_r        <= s_axi_awaddr;
                write_pending   <= 1'b1;

                case (s_axi_awaddr)
                    ADDR_HEADER: begin
                        req_op_axi      <= OP_HEADER_WORD;
                        req_data_axi    <= s_axi_wdata;
                        req_toggle_axi  <= ~req_toggle_axi;
                        write_needs_ack <= 1'b1;
                    end
                    ADDR_TARGET: begin
                        req_op_axi      <= OP_TARGET_WORD;
                        req_data_axi    <= s_axi_wdata;
                        req_toggle_axi  <= ~req_toggle_axi;
                        write_needs_ack <= 1'b1;
                    end
                    ADDR_CTRL: begin
                        req_data_axi <= s_axi_wdata;
                        if (s_axi_wdata[1]) begin
                            // bit1 (HOST_BREAK) takes priority if both bits are set
                            req_op_axi      <= OP_HOST_BREAK;
                            req_toggle_axi  <= ~req_toggle_axi;
                            write_needs_ack <= 1'b1;
                        end else if (s_axi_wdata[0]) begin
                            req_op_axi      <= OP_SOFT_RESET;
                            req_toggle_axi  <= ~req_toggle_axi;
                            write_needs_ack <= 1'b1;
                        end else begin
                            // wdata == 0: no bits set, nothing to do
                            write_needs_ack <= 1'b0;
                        end
                    end
                    default: begin
                        // Unmapped / read-only address written: ack immediately,
                        // no clk_h side effect.
                        write_needs_ack <= 1'b0;
                    end
                endcase
            end else begin
                s_axi_awready <= 1'b0;
                s_axi_wready  <= 1'b0;
            end

            // Retire the transaction: immediately if it had no clk_h side
            // effect, otherwise once the handshake below reports ack_pulse_axi.
            if (write_pending && !s_axi_bvalid) begin
                if (!write_needs_ack || ack_pulse_axi) begin
                    s_axi_bvalid  <= 1'b1;
                    s_axi_bresp   <= 2'b00; // OKAY
                    write_pending <= 1'b0;
                end
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // =====================================================================
    // AXI4-Lite read channel (single outstanding transaction, no side effects
    // except GOLDEN_NONCE clearing NONCE_VALID / irq)
    // =====================================================================
    reg read_pending;
    reg [C_S_AXI_ADDR_WIDTH-1:0] araddr_r;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rresp   <= 2'b00;
            read_pending  <= 1'b0;
            nonce_valid_axi_clear <= 1'b0;
        end else begin
            nonce_valid_axi_clear <= 1'b0;

            if (!read_pending && s_axi_arvalid && !s_axi_arready) begin
                s_axi_arready <= 1'b1;
                araddr_r      <= s_axi_araddr;
                read_pending  <= 1'b1;
            end else begin
                s_axi_arready <= 1'b0;
            end

            if (read_pending && !s_axi_rvalid) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp  <= 2'b00; // OKAY
                case (araddr_r)
                    ADDR_VERSION: s_axi_rdata <= VERSION;
                    ADDR_CTRL:    s_axi_rdata <= 32'h0; // write-only pulse bits
                    ADDR_STATUS:  s_axi_rdata <= {30'h0, nonce_valid_axi, hash_active_axi};
                    ADDR_NONCE: begin
                        s_axi_rdata           <= golden_nonce_axi;
                        nonce_valid_axi_clear <= 1'b1; // clears NONCE_VALID / irq below
                    end
                    default:      s_axi_rdata <= 32'h0;
                endcase
                read_pending <= 1'b0;
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    // =====================================================================
    // AXI (s_axi_aclk) -> hash core (clk_h) request/ack handshake
    //
    // Standard two-phase toggle synchronizer: req_toggle_axi is only ever
    // flipped once the previous request has been ack'd (enforced above by
    // stalling BVALID), so req_op_axi/req_data_axi are guaranteed stable
    // for the whole round trip and are safe to sample combinationally on
    // the clk_h side once the synchronized toggle edge is seen.
    // =====================================================================
    reg req_sync1_h, req_sync2_h, req_sync3_h;
    reg ack_toggle_h;
    reg ack_sync1_axi, ack_sync2_axi, ack_sync3_axi;

    wire req_pulse_h    = req_sync2_h ^ req_sync3_h;
    wire ack_pulse_axi  = ack_sync2_axi ^ ack_sync3_axi;

    always @(posedge clk_h) begin
        req_sync1_h <= req_toggle_axi;
        req_sync2_h <= req_sync1_h;
        req_sync3_h <= req_sync2_h;
        if (req_pulse_h)
            ack_toggle_h <= ~ack_toggle_h;
    end

    always @(posedge s_axi_aclk) begin
        ack_sync1_axi <= ack_toggle_h;
        ack_sync2_axi <= ack_sync1_axi;
        ack_sync3_axi <= ack_sync2_axi;
    end

    // =====================================================================
    // Hash-core (clk_h) domain: decode the request into the same pulses
    // odo_block_data / host_break_sm expect, and drive miner_top exactly
    // like exmaples/odocrypt/fpga/src/hdl/atomminer_odocrypt.v did.
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
            data_from_host_h <= req_data_axi;
            case (req_op_axi)
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
        .get_midstate_in  (1'b0),            // AXI side collapses midstate/block into one FIFO
        .get_block_in     (get_block_pulse_h),
        .get_target_in    (get_target_pulse_h),
        .header           (header),
        .target           (target)
    );

    host_break_sm host_break_sm_inst (
        .clk_h         (clk_h),
        .host_break    (host_break_pulse_h),
        .ticket2moon   (ticket2moon),
        .hash_cmplt    (1'b0),
        .sha_host_break(host_break_debounced)
    );

    miner_top miner_top_inst (
        .osc_clk    (clk_h),
        .header     (header),
        .target     (target),
        .start_hash (start_hash_h),
        .ticket2moon(ticket2moon),
        .nonce      (golden_nonce_h)
    );

    // -----------------------------------------------------------------
    // Result latch + clk_h -> AXI status/nonce synchronization.
    //
    // golden_nonce_h is a multi-bit bus crossed via a toggle event rather
    // than a full req/ack handshake: it's a "latest result" status
    // register, not a command stream, so the accepted race (a second
    // nonce landing mid-synchronization of the first) is the same class
    // of simplification real designs make for status/telemetry registers.
    // Tighten this to a full handshake (like the write path above) if
    // strict one-nonce-per-read semantics are required.
    // -----------------------------------------------------------------
    reg        nonce_toggle_h;
    reg [31:0] golden_nonce_latch_h;

    always @(posedge clk_h) begin
        if (ticket2moon) begin
            golden_nonce_latch_h <= golden_nonce_h;
            nonce_toggle_h       <= ~nonce_toggle_h;
        end
    end

    reg nonce_sync1_axi, nonce_sync2_axi, nonce_sync3_axi;
    reg hash_active_sync1_axi, hash_active_sync2_axi;
    reg [31:0] golden_nonce_axi;
    reg        nonce_valid_axi;
    reg        nonce_valid_axi_clear;
    wire       hash_active_axi = hash_active_sync2_axi;

    wire nonce_new_pulse_axi = nonce_sync2_axi ^ nonce_sync3_axi;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            nonce_sync1_axi <= 1'b0;
            nonce_sync2_axi <= 1'b0;
            nonce_sync3_axi <= 1'b0;
            hash_active_sync1_axi <= 1'b0;
            hash_active_sync2_axi <= 1'b0;
            nonce_valid_axi <= 1'b0;
            golden_nonce_axi <= 32'h0;
        end else begin
            nonce_sync1_axi <= nonce_toggle_h;
            nonce_sync2_axi <= nonce_sync1_axi;
            nonce_sync3_axi <= nonce_sync2_axi;

            hash_active_sync1_axi <= start_hash_h;
            hash_active_sync2_axi <= hash_active_sync1_axi;

            if (nonce_new_pulse_axi) begin
                golden_nonce_axi <= golden_nonce_latch_h;
                nonce_valid_axi  <= 1'b1;
            end else if (nonce_valid_axi_clear) begin
                nonce_valid_axi  <= 1'b0;
            end
        end
    end

    assign irq = nonce_valid_axi;

endmodule
