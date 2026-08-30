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
// am01_qmtech_top -- SCRATCH VARIANT, NOT THE REPO FILE.
//
// Identical to ../hardware/qmtech-kintex7/hdl/am01_qmtech_top.v except the
// odocrypt_gpio_wrapper instantiation below overrides NUM_MINERS to 2 (see nm1
// for the single-miner variant; these two differ ONLY in that parameter, so a
// comparison between them attributes cleanly to miner count)
// (420 RAMB18, ~47% occupancy) instead of the repo default of 2 (840
// RAMB18, ~94%). Built solely for a congestion-reduced openXC7
// place-and-route bring-up attempt -- see hardware/qmtech-kintex7/openxc7/
// README.md "router2 bounded termination". Not used by the Vivado build,
// not committed, not the file that produced the validated Vivado
// bitstream. Delete freely; regenerate from the real top level plus this
// one parameter override if needed again.
//
`timescale 1ns / 1ps

module am01_qmtech_top (
    input  wire        sys_clk_50m,

    inout  wire [15:0] gpio_data,
    input  wire [3:0]  gpio_addr,
    input  wire        gpio_wr_n,
    input  wire        gpio_rd_n,
    output wire        gpio_ready,
    output wire        gpio_irq,

    output wire [2:0]  status_led,
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
    // NUM_MINERS(2) override -- see file header. Repo default is 2.
    // -----------------------------------------------------------------
    odocrypt_gpio_wrapper #(
        .NUM_MINERS(2)
    ) odocrypt_gpio_wrapper_inst (
        .bus_clk   (bus_clk),
        .bus_rst_n (bus_rst_n),

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
