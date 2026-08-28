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
// am01_qmtech_top
//
// Top level for the QMTECH XC7K325T + Raspberry Pi CM4 variant. Wires the
// board's 50MHz crystal into clk_gen_hash (hash-core clock) and uses it
// directly as the GPIO-bus clock too (the async bus doesn't need a fast
// clock -- see odocrypt_gpio_wrapper.v's synchronizers), then instantiates
// odocrypt_gpio_wrapper. Pin names here match
// ../xdc/qmtech_xc7k325t_pinout.xdc exactly.
//
// STATUS: reference skeleton for a hardware proposal, not verified/timed
// silicon-ready RTL -- see ../README.md.
//
`timescale 1ns / 1ps

module am01_qmtech_top (
    input  wire        sys_clk_50m,

    inout  wire [15:0] gpio_data,
    input  wire [4:0]  gpio_addr,
    input  wire        gpio_wr_n,
    input  wire        gpio_rd_n,
    output wire        gpio_ready,
    output wire        gpio_irq,

    output wire [2:0]  status_led,

    // Fan on JP5's spare BANK12 I/O. Driven from fabric off the XADC die
    // temperature, so it runs correctly with no software involved.
    output wire        fan_pwm,
    input  wire        fan_tach_in,

    // ILI9341 panel + XPT2046 touch on JP5, one shared SPI bus.
    output wire        lcd_sclk,
    output wire        lcd_mosi,
    input  wire        lcd_miso,
    output wire        lcd_cs_n,
    output wire        lcd_dc,
    output wire        lcd_rst_n,
    output wire        lcd_bl,
    output wire        touch_cs_n,
    input  wire        touch_irq,
    input  wire        user_key_sw2,   // active low, used here as manual reset
    input  wire        user_key_sw3    // unused, reserved
);

    // -----------------------------------------------------------------
    // Clocking. clk_h feeds the hash core; the same 50MHz input is used
    // directly as bus_clk for the GPIO-bus front end (it's an
    // asynchronous handshake, not a fixed-rate protocol, so it doesn't
    // need to be fast -- see odocrypt_gpio_wrapper.v).
    // -----------------------------------------------------------------
    wire sys_clk_ibuf;
    IBUF ibuf_sys_clk (.I(sys_clk_50m), .O(sys_clk_ibuf));

    // clk_2x is 2 x clk_h off the same MMCM, phase-aligned. It exists for
    // the shared-BRAM S-boxes (see hdl/sbox_large_mux2.v). Nothing
    // consumes it yet -- the muxed core is applied to encrypt.v at build
    // time by tools/mux2_transform.py -- so synthesis will currently drop
    // its BUFG. It is generated here rather than later so that both
    // builds share one clocking source and the 2:1 phase alignment is a
    // property of the MMCM, not of whoever wires it up.
    wire clk_h, clk_2x, clk_h_locked;
    clk_gen_hash clk_gen_hash_inst (
        .clk_in      (sys_clk_ibuf),
        .rst         (1'b0),
        .clk_h       (clk_h),
        .clk_2x      (clk_2x),
        .clk_h_locked(clk_h_locked)
    );

    wire bus_clk = sys_clk_ibuf;

    // -----------------------------------------------------------------
    // Reset: MMCM lock, stretched a few cycles, ORed with the SW2 button
    // (active low) as a manual reset while bringing the board up.
    // -----------------------------------------------------------------
    reg [3:0] rst_stretch = 4'hF;
    wire      sw2_pressed = ~user_key_sw2;

    always @(posedge bus_clk) begin
        if (!clk_h_locked || sw2_pressed)
            rst_stretch <= 4'hF;
        else if (rst_stretch != 4'h0)
            rst_stretch <= rst_stretch - 1'b1;
    end

    wire bus_rst_n = (rst_stretch == 4'h0);

    // -----------------------------------------------------------------
    // GPIO-bus wrapper -> hash core.
    // -----------------------------------------------------------------
    odocrypt_gpio_wrapper odocrypt_gpio_wrapper_inst (
        .bus_clk   (bus_clk),
        .bus_rst_n (bus_rst_n),

        .fan_pwm     (fan_pwm),
        .fan_tach_in (fan_tach_in),

        .lcd_sclk   (lcd_sclk),
        .lcd_mosi   (lcd_mosi),
        .lcd_miso   (lcd_miso),
        .lcd_cs_n   (lcd_cs_n),
        .lcd_dc     (lcd_dc),
        .lcd_rst_n  (lcd_rst_n),
        .lcd_bl     (lcd_bl),
        .touch_cs_n (touch_cs_n),
        .touch_irq  (touch_irq),

        .gpio_data (gpio_data),
        .gpio_addr (gpio_addr),
        .gpio_wr_n (gpio_wr_n),
        .gpio_rd_n (gpio_rd_n),
        .gpio_ready(gpio_ready),
        .gpio_irq  (gpio_irq),

        .clk_h     (clk_h)
    );

    // -----------------------------------------------------------------
    // Bring-up status LEDs: prove clocking/reset before exercising the
    // CM4 link at all. LED0 = MMCM locked, LED1 = clk_h heartbeat blink.
    // -----------------------------------------------------------------
    reg [24:0] heartbeat_cnt = 25'h0;
    always @(posedge clk_h)
        heartbeat_cnt <= heartbeat_cnt + 1'b1;

    assign status_led[0] = clk_h_locked;
    assign status_led[1] = heartbeat_cnt[24];
    assign status_led[2] = 1'b0; // reserved

endmodule
