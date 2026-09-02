// tb_uart_tx_pin.v -- DECODE THE PIN, NOT THE MODULE'S OWN OPINION OF IT.
//
// THE BLIND SPOT THIS CLOSES. tb_uart_bridge exercises the transmitter by
// wiring uart_tx straight back into uart_rx and checking the byte survives the
// round trip. That is a genuinely useful test of the FIFOs and the baud
// divisor, and it passes -- but it cannot see any fault that is SYMMETRIC.
// Invert the line and both ends invert together and the loopback still passes.
// Reverse the bit order and both ends reverse and it still passes. Move the
// stop bit and both ends agree. A loopback validates that the module agrees
// with itself; it says nothing about whether it agrees with an ESP32.
//
// That matters here because the observed hardware symptom is exactly what a
// symmetric fault produces: the panel's bytes reach the FPGA perfectly, the
// FPGA transmits at a measured 11,515 B/s -- line rate to four digits, so the
// timing is certainly right -- and the ESP32 ROM, sitting in download mode,
// answers none of it. Correct rate with zero comprehension is the signature of
// right bits sent the wrong way round.
//
// So this bench decodes cyd_uart_tx with a receiver written from the RS-232
// line format alone: idle high, one low start bit, eight data bits LSB FIRST,
// one high stop bit. It shares no code and no parameters with the DUT. If the
// wrapper's framing disagrees with the wire standard in any way, this fails
// where the loopback cannot.
//
// It drives the byte in through the real GPIO bus, so what it checks is the
// whole path a host write actually takes -- bus decode, FIFO, shifter, pin.
//
// Run:
//   iverilog -g2005 -o /tmp/tbpin sim/tb_uart_tx_pin.v sim/stub_wrapper_deps.v \
//       hdl/odocrypt_gpio_wrapper.v hdl/uart_bridge.v hdl/found_path.v \
//       && vvp /tmp/tbpin

`timescale 1ns / 1ps

module tb_uart_tx_pin;

    localparam ADDR_UART_DATA = 5'h19;

    // The bus clock the wrapper actually runs at, and the bit period that
    // follows from it. Stated independently of the DUT on purpose: if
    // uart_bridge's DIVISOR is wrong, the sampling here drifts off the eye and
    // the decode fails, which is the correct outcome.
    localparam real CLK_NS   = 20.0;                   // 50MHz
    localparam real BIT_NS   = 1000000000.0 / 115200.0; // 8680.6ns

    reg clk = 1'b0;
    always #(CLK_NS/2.0) clk = ~clk;
    reg rst_n = 1'b0;

    reg  [15:0] gpio_data_o = 16'h0;
    wire [15:0] gpio_data   = gpio_data_o;
    reg  [4:0]  gpio_addr   = 5'h0;
    reg         gpio_wr_n   = 1'b1;
    reg         gpio_rd_n   = 1'b1;
    wire        gpio_ready, gpio_irq;

    wire tx_pin;                        // THE THING UNDER TEST

    odocrypt_gpio_wrapper dut (
        .bus_clk    (clk),
        .bus_rst_n  (rst_n),
        .fan_pwm    (), .fan_tach_in(1'b0),
        .lcd_sclk(), .lcd_mosi(), .lcd_miso(1'b0), .lcd_cs_n(),
        .lcd_dc(), .lcd_rst_n(), .lcd_bl(), .touch_cs_n(), .touch_irq(1'b0),
        .cyd_uart_tx(tx_pin), .cyd_uart_rx(1'b1),
        .cyd_esp_en(), .cyd_esp_io0(),
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

    task bus_write(input [4:0] a, input [15:0] d);
        begin
            @(negedge clk);
            gpio_addr   <= a;
            gpio_data_o <= d;
            @(negedge clk);
            gpio_wr_n <= 1'b0;
            wait (gpio_ready == 1'b1);
            #20000;                     // a realistic CM4 hold
            @(negedge clk);
            gpio_wr_n <= 1'b1;
            wait (gpio_ready == 1'b0);
            @(negedge clk);
        end
    endtask

    // A receiver built from the line format, sharing nothing with the DUT.
    // Samples the MIDDLE of every bit, which is what a real UART does and what
    // makes the result sensitive to a wrong baud rate as well as wrong framing.
    task recv_byte(output [7:0] b, output ok);
        integer k;
        reg stop_bit, start_bit;
        begin
            b = 8'h00; ok = 1'b1;
            @(negedge tx_pin);          // start bit edge
            #(BIT_NS/2.0);              // centre of the start bit
            start_bit = tx_pin;
            if (start_bit !== 1'b0) begin
                $display("  ..start bit is not low (saw %b)", start_bit);
                ok = 1'b0;
            end
            for (k = 0; k < 8; k = k + 1) begin
                #(BIT_NS);              // centre of data bit k
                b[k] = tx_pin;          // LSB FIRST, per the standard
            end
            #(BIT_NS);
            stop_bit = tx_pin;
            if (stop_bit !== 1'b1) begin
                $display("  ..stop bit is not high (saw %b)", stop_bit);
                ok = 1'b0;
            end
        end
    endtask

    reg [7:0] got;
    reg       framing_ok;
    integer   i;
    reg [7:0] pattern [0:3];

    initial begin
        $display("=== tb_uart_tx_pin: does the PIN speak RS-232? ===");
        $display("");
        $display("Reference decoder: idle high, low start, 8 data LSB-first,");
        $display("high stop, %0.1fns per bit. Shares nothing with the DUT.", BIT_NS);
        $display("");

        // 0x55 and 0xAA are the ones that matter: each is the other's bit
        // reversal AND the other's inversion, so a pass on both rules out a
        // reversed or inverted line that a symmetric loopback would miss.
        pattern[0] = 8'h55;
        pattern[1] = 8'hAA;
        pattern[2] = 8'h41;             // 'A'
        pattern[3] = 8'h07;             // low bits set, high bits clear

        repeat (4) @(negedge clk);
        rst_n <= 1'b1;
        repeat (8) @(negedge clk);

        check(tx_pin === 1'b1, "line idles HIGH before anything is sent");

        for (i = 0; i < 4; i = i + 1) begin
            fork
                begin
                    recv_byte(got, framing_ok);
                end
                begin
                    repeat (4) @(negedge clk);
                    bus_write(ADDR_UART_DATA, {8'h00, pattern[i]});
                end
            join

            $display("  sent 0x%02x  ->  decoded 0x%02x", pattern[i], got);
            check(framing_ok, "start and stop bits are correctly placed");
            check(got === pattern[i], "decoded byte matches the byte written");

            // Let the line settle back to idle before the next one.
            #(BIT_NS * 3);
            check(tx_pin === 1'b1, "line returns to idle HIGH after the byte");
        end

        $display("");
        if (errors == 0)
            $display("=== PASS: the pin is standard-conformant RS-232 ===");
        else
            $display("=== %0d FAILURE(S) -- the wire format is wrong ===", errors);
        $display("");
        $finish;
    end

    // Never let a broken transmitter hang the run.
    initial begin
        #5000000;
        $display("TIMEOUT: no serial activity on the pin -- transmitter stalled");
        $display("=== FAIL (timeout) ===");
        $finish;
    end

endmodule
