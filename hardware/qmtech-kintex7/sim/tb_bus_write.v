// tb_bus_write.v -- ONE HOST WRITE MUST BE ONE SIDE EFFECT.
//
// THE TESTBENCH THIS TREE DID NOT HAVE, and its absence let a total failure
// of the CYD link ship. Every other bench here tests a LEAF module --
// uart_bridge, found_path -- in isolation, and both pass. The defect lived in
// odocrypt_gpio_wrapper's S_WRITE decode, which nothing instantiated.
//
// THE BUG. S_WRITE re-executes its case on every bus_clk until the CM4
// releases WR_N. A case body that sets a strobe therefore re-asserts it every
// cycle, and the `uart_tx_wr <= 1'b0` default at the top of the block never
// wins. One host write to ADDR_UART_DATA pushed the byte 4 times with WR_N
// released instantly, and 16 times -- filling the FIFO -- over the ~20us a
// real CM4 syscall takes. The panel received an unbroken run of one character
// and could never assemble a line, so it sat on MINER DOWN for ever.
//
// The read path was always right: it fires uart_rx_rd and the nonce ack from
// inside `if (gpio_ready && !rd_sync[2])`, at the END of the transaction.
// Only the write path was wrong.
//
// WHAT THIS BENCH ASSERTS is the property, not the implementation: hold WR_N
// for a range of durations spanning far past a realistic host, and require
// exactly one push each time.
//
// Run:
//   iverilog -g2005 -o /tmp/tb sim/tb_bus_write.v sim/stub_wrapper_deps.v \
//       hdl/odocrypt_gpio_wrapper.v hdl/uart_bridge.v hdl/found_path.v && vvp /tmp/tb

`timescale 1ns / 1ps

module tb_bus_write;

    localparam ADDR_UART_DATA = 5'h19;
    localparam ADDR_UART_STAT = 5'h1A;

    reg clk = 1'b0;
    always #10 clk = ~clk;              // 50MHz, the real bus_clk
    reg rst_n = 1'b0;

    reg  [15:0] gpio_data_o = 16'h0;
    reg         data_drive  = 1'b1;
    wire [15:0] gpio_data   = data_drive ? gpio_data_o : 16'hzzzz;
    reg  [4:0]  gpio_addr   = 5'h0;
    reg         gpio_wr_n   = 1'b1;
    reg         gpio_rd_n   = 1'b1;
    wire        gpio_ready, gpio_irq;

    odocrypt_gpio_wrapper dut (
        .bus_clk    (clk),
        .bus_rst_n  (rst_n),
        .fan_pwm    (), .fan_tach_in(1'b0),
        .lcd_sclk(), .lcd_mosi(), .lcd_miso(1'b0), .lcd_cs_n(),
        .lcd_dc(), .lcd_rst_n(), .lcd_bl(), .touch_cs_n(), .touch_irq(1'b0),
        .cyd_uart_tx(), .cyd_uart_rx(1'b1), .cyd_esp_en(), .cyd_esp_io0(),
        .gpio_data  (gpio_data),
        .gpio_addr  (gpio_addr),
        .gpio_wr_n  (gpio_wr_n),
        .gpio_rd_n  (gpio_rd_n),
        .gpio_ready (gpio_ready),
        .gpio_irq   (gpio_irq),
        .clk_h      (clk)
    );

    integer errors = 0;
    task check(input cond, input [1023:0] what);
        begin
            if (cond) $display("  PASS  %0s", what);
            else begin $display("  FAIL  %0s", what); errors = errors + 1; end
        end
    endtask

    // One CM4-style 4-phase write, holding WR_N for `hold_ns` past READY --
    // exactly what a userspace libgpiod write does, where the hold time is a
    // syscall and therefore long and variable.
    task bus_write(input [4:0] a, input [15:0] d, input integer hold_ns);
        begin
            @(negedge clk);
            gpio_addr   <= a;
            gpio_data_o <= d;
            data_drive  <= 1'b1;
            @(negedge clk);
            gpio_wr_n <= 1'b0;
            wait (gpio_ready == 1'b1);
            if (hold_ns > 0) #(hold_ns);
            @(negedge clk);
            gpio_wr_n <= 1'b1;
            wait (gpio_ready == 1'b0);
            @(negedge clk);
        end
    endtask

    // THE WRITE POINTER, not the FIFO occupancy.
    //
    // uart_tx_cnt was the obvious choice and is the WRONG observable: the
    // transmitter pops the first byte into its shift register the moment the
    // FIFO is non-empty, so a correct single write reads back as count 0 and
    // a doubled one as 1. The first version of this bench measured that and
    // "failed" against correct RTL for the wrong reason.
    //
    // tx_wr_ptr only ever increments, and only on a push, so its delta is
    // exactly the number of times the byte was queued. */
    wire [4:0] tx_wr_ptr = dut.uart_i.tx_wr_ptr;

    integer i;
    integer holds [0:4];
    reg [4:0] cnt;

    initial begin
        $display("=== tb_bus_write: one host write == one side effect ===");
        $display("");

        holds[0] = 0;        // WR_N released the instant READY rises
        holds[1] = 100;      // 100ns
        holds[2] = 500;      // 500ns
        holds[3] = 5000;     // 5us
        holds[4] = 20000;    // 20us -- the measured cost of a real CM4 write

        repeat (4) @(negedge clk);
        rst_n <= 1'b1;
        repeat (8) @(negedge clk);

        for (i = 0; i < 5; i = i + 1) begin
            // Drain: reset between cases so each starts from an empty FIFO.
            rst_n <= 1'b0;
            repeat (4) @(negedge clk);
            rst_n <= 1'b1;
            repeat (8) @(negedge clk);

            bus_write(ADDR_UART_DATA, 16'h0041, holds[i]);   // 'A'
            repeat (4) @(negedge clk);
            cnt = tx_wr_ptr;

            $display("  WR_N held %6d ns past READY -> pushes = %0d",
                     holds[i], cnt);
            check(cnt == 5'd1,
                  "exactly ONE byte queued for this write");
        end

        $display("");
        $display("-- and the same for a second, different byte --");
        // Two writes back to back must give exactly two bytes: this catches a
        // fix that clamps to one push per RESET rather than per transaction.
        rst_n <= 1'b0;
        repeat (4) @(negedge clk);
        rst_n <= 1'b1;
        repeat (8) @(negedge clk);

        bus_write(ADDR_UART_DATA, 16'h0041, 2000);
        bus_write(ADDR_UART_DATA, 16'h0042, 2000);
        repeat (4) @(negedge clk);
        cnt = tx_wr_ptr;
        $display("  two writes -> pushes = %0d", cnt);
        check(cnt == 5'd2, "two writes queue exactly TWO bytes");

        $display("");
        if (errors == 0) $display("=== ALL CHECKS PASSED ===");
        else             $display("=== %0d CHECK(S) FAILED ===", errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("=== TIMEOUT ===");
        $finish;
    end

endmodule
