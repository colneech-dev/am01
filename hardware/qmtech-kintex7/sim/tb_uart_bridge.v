// tb_uart_bridge.v -- unit test for uart_bridge.v.
//
// Written BEFORE the module is instantiated in the wrapper, deliberately.
// found_path.v was done this way and it caught two real bugs that would
// otherwise each have cost a ~1h35m Vivado build and a flash cycle to find.
//
// Runs in about a second: no cipher, no XADC, nothing that needs the rest of
// the design. That is the whole reason this module exists standalone.
//
// Uses a deliberately small DIVISOR so a byte takes tens of cycles rather than
// thousands. The logic under test is identical -- only the counter terminal
// value changes -- and a realistic 434 would make the run minutes long for no
// extra coverage.
//
// Run:
//   iverilog -g2005 -o /tmp/tb sim/tb_uart_bridge.v hdl/uart_bridge.v && vvp /tmp/tb

`timescale 1ns / 1ps

module tb_uart_bridge;

    localparam integer CLK_HZ  = 1_000_000;
    localparam integer BAUD    = 50_000;      // DIVISOR = 20
    localparam integer DIVISOR = CLK_HZ / BAUD;
    localparam integer FIFO_AW = 4;
    localparam integer DEPTH   = (1 << FIFO_AW);

    reg clk = 1'b0;
    always #0.5 clk = ~clk;                   // 1 MHz
    reg rst_n = 1'b0;

    reg        tx_wr   = 1'b0;
    reg  [7:0] tx_data = 8'h0;
    wire       tx_full;
    reg        rx_rd   = 1'b0;
    wire [7:0] rx_data;
    wire       rx_empty;
    wire [FIFO_AW:0] tx_count;
    /* 8 bits: rx_count is EXACT for the 128-deep RX FIFO, and wider than
     * tx_count because the RX side is the one the host does not control. */
    wire [15:0]      rx_count;
    wire [7:0] rx_err;

    wire       uart_tx;

    // LOOPBACK by default: the transmitter drives the receiver, so a byte
    // written must come back out. Overridden by force in the framing test.
    reg  loop_en = 1'b1;
    reg  rx_drive = 1'b1;
    wire uart_rx = loop_en ? uart_tx : rx_drive;

    uart_bridge #(
        .CLK_HZ(CLK_HZ), .BAUD(BAUD), .FIFO_AW(FIFO_AW)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .tx_wr(tx_wr), .tx_data(tx_data), .tx_full(tx_full),
        .rx_rd(rx_rd), .rx_data(rx_data), .rx_empty(rx_empty),
        .tx_count(tx_count), .rx_count(rx_count), .rx_err(rx_err),
        .uart_tx(uart_tx), .uart_rx(uart_rx)
    );

    // ---- second instance, for the baud-tolerance test --------------------
    // A separate DUT because DIVISOR is fixed at elaboration and the tolerance
    // test needs one large enough that a few percent is still a whole number
    // of clocks. DIVISOR=100 here, so +/-3% is 103 / 97 cycles per bit.
    reg        tol_rx = 1'b1;
    wire [7:0] tol_data;
    wire       tol_empty;
    wire [7:0] tol_err;
    reg        tol_rd = 1'b0;

    uart_bridge #(
        .CLK_HZ(CLK_HZ), .BAUD(10_000), .FIFO_AW(FIFO_AW)
    ) dut_tol (
        .clk(clk), .rst_n(rst_n),
        .tx_wr(1'b0), .tx_data(8'h0), .tx_full(),
        .rx_rd(tol_rd), .rx_data(tol_data), .rx_empty(tol_empty),
        .tx_count(), .rx_count(), .rx_err(tol_err),
        .uart_tx(), .uart_rx(tol_rx)
    );

    localparam integer TOL_DIV = CLK_HZ / 10_000;   // 100

    // Drive one byte onto dut_tol at a deliberately WRONG bit period.
    task tol_send(input [7:0] b, input integer period);
        integer k, j;
        begin
            tol_rx = 1'b0;                                  // start
            for (k = 0; k < period; k = k + 1) @(negedge clk);
            for (j = 0; j < 8; j = j + 1) begin
                tol_rx = (b >> j) & 1'b1;
                for (k = 0; k < period; k = k + 1) @(negedge clk);
            end
            tol_rx = 1'b1;                                  // stop
            for (k = 0; k < period; k = k + 1) @(negedge clk);
        end
    endtask

    integer errors = 0;
    task check(input cond, input [1023:0] what);
        begin
            if (cond) $display("  PASS  %0s", what);
            else begin $display("  FAIL  %0s", what); errors = errors + 1; end
        end
    endtask

    task push(input [7:0] b);
        begin
            @(negedge clk);
            tx_data <= b; tx_wr <= 1'b1;
            @(negedge clk);
            tx_wr <= 1'b0;
        end
    endtask

    task pop(output [7:0] b);
        begin
            @(negedge clk);
            b = rx_data;          // combinational read, before the pointer moves
            rx_rd <= 1'b1;
            @(negedge clk);
            rx_rd <= 1'b0;
        end
    endtask

    // One bit time, for hand-driving the line in the framing test.
    task bit_time; begin repeat (DIVISOR) @(negedge clk); end endtask

    reg [7:0] got, got2;
    integer i, ordered;

    initial begin
        $display("=== tb_uart_bridge: DIVISOR=%0d FIFO=%0d ===", DIVISOR, DEPTH);

        repeat (4) @(negedge clk);

        // ---- T1: the line is high WHILE HELD IN RESET ----------------------
        // Checked here, before rst_n is released, and that placement is the
        // whole point. Checking it a few cycles later instead only proves
        // TX_IDLE drives high -- which it does even if the reset value is
        // wrong, because TX_IDLE reasserts it within one cycle. A mutant that
        // reset uart_tx to 0 passed the weaker version of this check.
        //
        // It matters on real hardware: a line low at reset reads as a start
        // bit at the far end, so the panel's first byte after a reset is
        // garbage -- and it looks like a wiring fault, not a reset bug.
        check(uart_tx === 1'b1, "TX is high while held in reset");

        rst_n <= 1'b1;
        repeat (4) @(negedge clk);
        check(uart_tx === 1'b1, "TX still high once released and idle");
        check(rx_empty === 1'b1, "RX starts empty");
        check(tx_count === 0,    "TX FIFO starts empty");

        // ---- T2: one byte, there and back ----------------------------------
        push(8'hA5);
        repeat (DIVISOR * 12) @(negedge clk);
        check(!rx_empty, "a transmitted byte arrives back over the loopback");
        pop(got);
        check(got === 8'hA5, "and it is the byte that was sent (0xA5)");

        // ---- T3: 0x00 and 0xFF -------------------------------------------
        // The two bytes most likely to expose a framing error: all-zero holds
        // the line at the start-bit level for the whole byte, all-ones holds
        // it at the stop-bit level. A receiver that mistakes data for framing
        // fails on exactly these and on nothing else.
        push(8'h00);
        repeat (DIVISOR * 12) @(negedge clk);
        pop(got);
        check(got === 8'h00, "0x00 survives (data cannot be mistaken for a start bit)");

        push(8'hFF);
        repeat (DIVISOR * 12) @(negedge clk);
        pop(got);
        check(got === 8'hFF, "0xFF survives (data cannot be mistaken for a stop bit)");

        // ---- T4: a burst, in order ----------------------------------------
        // This is what the link actually does: the host writes a whole status
        // line at once and the FIFO drains it at line rate.
        for (i = 0; i < 8; i = i + 1) push(8'h10 + i[7:0]);
        check(tx_count > 0, "a burst queues in the TX FIFO rather than being lost");
        repeat (DIVISOR * 12 * 9) @(negedge clk);
        check(rx_count === 8, "all 8 bytes of the burst arrive");
        ordered = 1;
        for (i = 0; i < 8; i = i + 1) begin
            pop(got);
            if (got !== (8'h10 + i[7:0])) ordered = 0;
        end
        check(ordered, "and in the order they were sent");
        check(rx_err === 8'h0, "no framing errors over a clean loopback");

        // ---- T5: TX FIFO full is visible, not silent ------------------------
        for (i = 0; i < DEPTH + 4; i = i + 1) push(8'hC0 + i[7:0]);
        check(tx_full === 1'b1, "TX FIFO reports full rather than silently dropping");
        repeat (DIVISOR * 12 * (DEPTH + 2)) @(negedge clk);
        check(tx_full === 1'b0, "and clears once it has drained");

        // drain the RX side so the next test starts clean
        while (!rx_empty) pop(got);

        // ---- T6: framing error is COUNTED, and the byte is dropped ----------
        // Hand-drive a byte with a LOW stop bit. A receiver that delivers this
        // anyway hands the panel a value it will act on; one that drops it
        // silently makes a corrupting link look like a software bug. Neither
        // is acceptable, so it must be dropped AND counted.
        loop_en  = 1'b0;
        rx_drive = 1'b1;
        repeat (DIVISOR) @(negedge clk);
        rx_drive = 1'b0; bit_time;              // start
        for (i = 0; i < 8; i = i + 1) begin     // data 0x5A
            rx_drive = (8'h5A >> i) & 1'b1;
            bit_time;
        end
        rx_drive = 1'b0; bit_time;              // BAD stop bit (should be 1)
        rx_drive = 1'b1;
        repeat (DIVISOR * 2) @(negedge clk);

        check(rx_err !== 8'h0, "a bad stop bit is counted as a framing error");
        check(rx_empty === 1'b1, "and the corrupt byte is NOT delivered");

        // ---- T7: recovery --------------------------------------------------
        // A link that never recovers from one bad byte is not usable: noise
        // happens, and the panel must not need a power cycle to resync.
        loop_en = 1'b1;
        repeat (DIVISOR * 2) @(negedge clk);
        push(8'h3C);
        repeat (DIVISOR * 12) @(negedge clk);
        check(!rx_empty, "the receiver resynchronises after a framing error");
        pop(got);
        check(got === 8'h3C, "and the next byte is correct");

        // ---- T8: tolerance to a MISMATCHED baud rate -----------------------
        // The real link has an FPGA clock at one end and an ESP32 crystal at
        // the other; they will never agree exactly. Mid-bit sampling is what
        // buys tolerance to that, and a loopback cannot show it because both
        // ends share one clock and align perfectly.
        //
        // This is the check that distinguishes a correct receiver from one
        // sampling at the bit EDGE. A mutant doing the latter passed every
        // other test in this file, which is precisely why this one exists:
        // it would have shipped a receiver that worked on the bench and
        // failed against real hardware.
        tol_rd = 1'b0;
        repeat (TOL_DIV) @(negedge clk);

        tol_send(8'h5A, TOL_DIV + 3);          // sender ~3% SLOW
        repeat (TOL_DIV * 2) @(negedge clk);
        check(!tol_empty, "a byte sent 3% SLOW is still received");
        if (!tol_empty) begin
            got2 = tol_data;
            @(negedge clk); tol_rd <= 1'b1; @(negedge clk); tol_rd <= 1'b0;
            check(got2 === 8'h5A, "and it is correct (0x5A)");
        end else check(1'b0, "and it is correct (0x5A)");

        tol_send(8'hA5, TOL_DIV - 3);          // sender ~3% FAST
        repeat (TOL_DIV * 2) @(negedge clk);
        check(!tol_empty, "a byte sent 3% FAST is still received");
        if (!tol_empty) begin
            got2 = tol_data;
            @(negedge clk); tol_rd <= 1'b1; @(negedge clk); tol_rd <= 1'b0;
            check(got2 === 8'hA5, "and it is correct (0xA5)");
        end else check(1'b0, "and it is correct (0xA5)");

        check(tol_err === 8'h0, "no framing errors at +/-3% baud mismatch");

        $display("");
        if (errors == 0) $display("=== ALL CHECKS PASSED ===");
        else             $display("=== %0d CHECK(S) FAILED ===", errors);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("=== TIMEOUT ===");
        $finish;
    end

endmodule
