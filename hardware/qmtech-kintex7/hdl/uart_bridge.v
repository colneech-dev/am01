// uart_bridge.v -- UART for the CYD front panel, with FIFOs both directions.
//
// NOT INSTANTIATED ANYWHERE YET. The wrapper still drives the ILI9341 on these
// JP5 pins and is untouched; this is built and tested standalone first, the
// same order found_path.v was done in. That order caught two real bugs before
// they reached a bitstream, each of which would otherwise have cost a ~1h35m
// build and a flash cycle to discover.
//
// See docs/PLAN-cyd-display.md. Briefly: no CM4 GPIO reaches a connector, so
// the only path to an external panel is Pi -> parallel bus -> FPGA -> JP5. The
// FPGA has to host the UART because it is the only thing that can reach both
// ends.
//
// LIVES IN bus_clk (50MHz), deliberately -- the same domain as the register
// bus and the existing SPI block. A UART at 115200 needs nothing faster, and
// putting it here means the register interface needs no clock crossing at all.
// The found-nonce path needs a CDC because the hash core must run at 133MHz;
// this does not, so it should not have one. Every CDC is a chance to get it
// wrong, and this design has already paid for one of those.
//
// WHY 115200. The payload is one status line per second. The entire reason for
// leaving SPI behind is that 6.25MHz over jumper wires does not work on this
// board, so spending the recovered timing margin to go faster would be
// perverse: at 115200 a bit is 8.7us against that SPI's 160ns.

module uart_bridge #(
    // Defaults match this board: bus_clk is sys_clk_50m straight through.
    parameter integer CLK_HZ  = 50_000_000,
    parameter integer BAUD    = 115200,
    // 16 deep each way. The Pi writes in bursts over a bus whose per-access
    // cost is a syscall, so a FIFO is what stops it having to babysit the line
    // a byte at a time; 16 covers a burst without being worth more BRAM.
    parameter integer FIFO_AW = 4,
    /* RX IS DEEPER THAN TX, and deliberately so.
     *
     * The host WRITES the TX FIFO, so it knows what it has put in and depth
     * buys it nothing. It does not control when bytes ARRIVE, and at 115200 a
     * 16-byte RX FIFO overflows after 1.4ms of not being read -- which is a
     * deadline no software thread that also does other work can honour. 8 ->
     * 256 bytes -> 22ms, which it can.
     *
     * THE DEPTH IS CHOSEN FOR THE DEADLINE, not to fit a bitfield. An earlier
     * version picked 128 so the count would fit 8 spare bits in the status
     * register -- letting the register map size the hardware, which is
     * backwards. rx_count now has a register of its own and is 16 bits, so
     * this can be whatever the timing argument says it should be.
     *
     * Costs 256 bytes of distributed RAM. */
    parameter integer RX_FIFO_AW = 8
) (
    input  wire       clk,
    input  wire       rst_n,

    // ---- register side -------------------------------------------------
    input  wire       tx_wr,        // 1-cycle strobe: push tx_data
    input  wire [7:0] tx_data,
    output wire       tx_full,

    input  wire       rx_rd,        // 1-cycle strobe: pop rx_data
    output wire [7:0] rx_data,
    output wire       rx_empty,

    output wire [FIFO_AW:0] tx_count,
    /* 16 bits, and exact for any depth this FIFO will ever have. It has its
     * own register (ADDR_UART_RXCNT), so it is not competing for space with
     * anything and never needs to saturate. */
    output wire [15:0]      rx_count,
    // Framing errors seen. Saturating, and exposed rather than silently
    // dropped: a link that is quietly corrupting bytes looks exactly like a
    // panel with a software bug, and telling those apart afterwards is
    // expensive.
    output reg  [7:0] rx_err,

    // ---- pins ----------------------------------------------------------
    output reg        uart_tx,
    input  wire       uart_rx
);

    localparam integer DIVISOR   = CLK_HZ / BAUD;      // 434 at 50MHz/115200
    localparam integer DIV_W     = $clog2(DIVISOR + 1);
    localparam integer FIFO_DEPTH    = (1 << FIFO_AW);
    localparam integer RX_FIFO_DEPTH = (1 << RX_FIFO_AW);


    // =====================================================================
    // TX FIFO
    // =====================================================================
    reg  [7:0]        tx_mem [0:FIFO_DEPTH-1];
    reg  [FIFO_AW:0]  tx_wr_ptr, tx_rd_ptr;
    wire [FIFO_AW:0]  tx_fill  = tx_wr_ptr - tx_rd_ptr;
    wire              tx_empty = (tx_wr_ptr == tx_rd_ptr);

    assign tx_full  = (tx_fill == FIFO_DEPTH[FIFO_AW:0]);
    assign tx_count = tx_fill;

    // =====================================================================
    // RX FIFO
    // =====================================================================
    reg  [7:0]           rx_mem [0:RX_FIFO_DEPTH-1];
    reg  [RX_FIFO_AW:0]  rx_wr_ptr, rx_rd_ptr;
    wire [RX_FIFO_AW:0]  rx_fill  = rx_wr_ptr - rx_rd_ptr;
    wire                 rx_full  = (rx_fill == RX_FIFO_DEPTH[RX_FIFO_AW:0]);

    assign rx_empty = (rx_wr_ptr == rx_rd_ptr);
    /* Zero-extended into 16 bits. Exact for any RX_FIFO_AW up to 15. */
    assign rx_count = {{(16-(RX_FIFO_AW+1)){1'b0}}, rx_fill};
    assign rx_data  = rx_mem[rx_rd_ptr[RX_FIFO_AW-1:0]];

    // =====================================================================
    // Transmitter: start bit, 8 data bits LSB first, one stop bit.
    // =====================================================================
    localparam [1:0] TX_IDLE = 2'd0, TX_START = 2'd1,
                     TX_DATA = 2'd2, TX_STOP  = 2'd3;

    reg [1:0]        tx_state;
    reg [DIV_W-1:0]  tx_div;
    reg [2:0]        tx_bit;
    reg [7:0]        tx_sr;

    always @(posedge clk) begin
        if (!rst_n) begin
            tx_state  <= TX_IDLE;
            tx_div    <= 0;
            tx_bit    <= 3'd0;
            tx_sr     <= 8'h0;
            tx_rd_ptr <= 0;
            // Idle HIGH. A UART line idles high, and coming out of reset low
            // would look to the far end like a start bit -- so the panel's
            // first byte after a reset would be framing garbage.
            uart_tx   <= 1'b1;
        end else begin
            case (tx_state)
            TX_IDLE: begin
                uart_tx <= 1'b1;
                if (!tx_empty) begin
                    tx_sr     <= tx_mem[tx_rd_ptr[FIFO_AW-1:0]];
                    tx_rd_ptr <= tx_rd_ptr + 1'b1;
                    tx_div    <= 0;
                    uart_tx   <= 1'b0;          // start bit
                    tx_state  <= TX_START;
                end
            end
            TX_START:
                if (tx_div == DIVISOR[DIV_W-1:0] - 1) begin
                    tx_div   <= 0;
                    tx_bit   <= 3'd0;
                    uart_tx  <= tx_sr[0];
                    tx_state <= TX_DATA;
                end else tx_div <= tx_div + 1'b1;
            TX_DATA:
                if (tx_div == DIVISOR[DIV_W-1:0] - 1) begin
                    tx_div <= 0;
                    if (tx_bit == 3'd7) begin
                        uart_tx  <= 1'b1;       // stop bit
                        tx_state <= TX_STOP;
                    end else begin
                        tx_sr   <= {1'b0, tx_sr[7:1]};
                        uart_tx <= tx_sr[1];
                        tx_bit  <= tx_bit + 1'b1;
                    end
                end else tx_div <= tx_div + 1'b1;
            TX_STOP:
                if (tx_div == DIVISOR[DIV_W-1:0] - 1) begin
                    tx_div   <= 0;
                    tx_state <= TX_IDLE;
                end else tx_div <= tx_div + 1'b1;
            endcase
        end
    end

    // TX FIFO write port. Separate always block from the shifter above so each
    // pointer has exactly one driver -- tx_wr_ptr here, tx_rd_ptr there.
    always @(posedge clk) begin
        if (!rst_n) begin
            tx_wr_ptr <= 0;
        end else if (tx_wr && !tx_full) begin
            tx_mem[tx_wr_ptr[FIFO_AW-1:0]] <= tx_data;
            tx_wr_ptr <= tx_wr_ptr + 1'b1;
        end
        // A write into a full FIFO is DROPPED, not blocked, and not counted:
        // the host can see tx_full before writing, so a drop here is a host
        // bug rather than a link condition, and inventing a counter for it
        // would imply the link was at fault.
    end

    // =====================================================================
    // Receiver.
    //
    // Two-flop synchroniser first: uart_rx arrives from another board with its
    // own clock and is genuinely asynchronous. Sampling it straight into the
    // state machine is the classic way to get a metastable start-bit detect
    // that works on the bench and fails in a warm case.
    // =====================================================================
    (* ASYNC_REG = "TRUE" *) reg rx_sync1;
    reg rx_sync2, rx_sync3;

    always @(posedge clk) begin
        if (!rst_n) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
            rx_sync3 <= 1'b1;
        end else begin
            rx_sync1 <= uart_rx;
            rx_sync2 <= rx_sync1;
            rx_sync3 <= rx_sync2;
        end
    end

    wire rx_fall = rx_sync3 & ~rx_sync2;   // idle-high line going low = start

    localparam [1:0] RX_IDLE = 2'd0, RX_START = 2'd1,
                     RX_DATA = 2'd2, RX_STOP  = 2'd3;

    reg [1:0]       rx_state;
    reg [DIV_W-1:0] rx_div;
    reg [2:0]       rx_bit;
    reg [7:0]       rx_sr;

    always @(posedge clk) begin
        if (!rst_n) begin
            rx_state  <= RX_IDLE;
            rx_div    <= 0;
            rx_bit    <= 3'd0;
            rx_sr     <= 8'h0;
            rx_wr_ptr <= 0;
            rx_err    <= 8'h0;
        end else begin
            case (rx_state)
            RX_IDLE:
                if (rx_fall) begin
                    rx_div   <= 0;
                    rx_state <= RX_START;
                end
            RX_START:
                // Half a bit, to reach the MIDDLE of the start bit. Sampling
                // at the edges is what makes a receiver work against a clean
                // generator and fail against a real one with any skew.
                if (rx_div == (DIVISOR[DIV_W-1:0] >> 1) - 1) begin
                    rx_div <= 0;
                    if (rx_sync2) begin
                        // Gone high again by mid-bit: a glitch, not a start.
                        // Not a framing error -- nothing was framed.
                        rx_state <= RX_IDLE;
                    end else begin
                        rx_bit   <= 3'd0;
                        rx_state <= RX_DATA;
                    end
                end else rx_div <= rx_div + 1'b1;
            RX_DATA:
                if (rx_div == DIVISOR[DIV_W-1:0] - 1) begin
                    rx_div <= 0;
                    rx_sr  <= {rx_sync2, rx_sr[7:1]};   // LSB first
                    if (rx_bit == 3'd7) rx_state <= RX_STOP;
                    else                rx_bit   <= rx_bit + 1'b1;
                end else rx_div <= rx_div + 1'b1;
            RX_STOP:
                if (rx_div == DIVISOR[DIV_W-1:0] - 1) begin
                    rx_div   <= 0;
                    rx_state <= RX_IDLE;
                    if (!rx_sync2) begin
                        // Stop bit low: the byte is not trustworthy. Count it
                        // and drop it. Delivering a byte known to be bad is
                        // worse than losing it -- the panel would act on it.
                        if (rx_err != 8'hFF) rx_err <= rx_err + 1'b1;
                    end else if (!rx_full) begin
                        rx_mem[rx_wr_ptr[RX_FIFO_AW-1:0]] <= rx_sr;
                        rx_wr_ptr <= rx_wr_ptr + 1'b1;
                    end else begin
                        // Overrun. Same counter: from the host's point of view
                        // "a byte went missing" is one problem, and splitting
                        // it across two registers helps nobody.
                        if (rx_err != 8'hFF) rx_err <= rx_err + 1'b1;
                    end
                end else rx_div <= rx_div + 1'b1;
            endcase
        end
    end

    // RX FIFO read port. Its own block, so rx_rd_ptr has one driver.
    always @(posedge clk) begin
        if (!rst_n)                    rx_rd_ptr <= 0;
        else if (rx_rd && !rx_empty)   rx_rd_ptr <= rx_rd_ptr + 1'b1;
    end

endmodule
