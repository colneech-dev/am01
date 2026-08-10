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
// clk_gen_hash
//
// Generates the hash-core clock (clk_h, feeds miner_top the way AM01's
// artix200_v3_clocking does today) from the QMTECH board's onboard 50MHz
// crystal. Written as a raw MMCME2_BASE instantiation rather than a
// Vivado-generated Clocking Wizard IP (.xci) so this project can be
// scaffolded from the command line (see ../vivado/build.tcl) without
// needing to click through IP Integrator.
//
// STATUS / TODO: CLKFBOUT_MULT / CLKOUT0_DIVIDE below target 150MHz (50MHz
// x 15 / 5), not the earlier arbitrary 125MHz guess. 150MHz is grounded in
// a real cross-reference: exmaples/odocrypt/fpga/src/hdl/miner.v is the
// same upstream `THROUGHPUT 4` pipelined odo_encrypt core (MentalCollatz)
// that colneech-dev/odo-miner-cyclonev benchmarked on comparable-class
// fabric (QMTECH Cyclone V SoC, ~110K LE) -- Quartus reported Fmax =
// 162.1MHz @ Slow/85C for that exact core, and it's deployed at 156.25MHz
// on that board. 150MHz is the upstream reference clock (37.5MH/s at
// THROUGHPUT=4). Xilinx 7-series (-1 speed grade) should have at least as
// much headroom as that Cyclone V part, but this is still a cross-vendor,
// cross-part estimate, not a Vivado STA result for THIS wrapper on THIS
// XC7K325T-1FFG676C -- re-verify from post-synthesis timing and retune if
// it doesn't close.
//
`timescale 1ns / 1ps

module clk_gen_hash #(
    parameter CLKIN_PERIOD_NS = 20.000, // 50MHz input
    parameter CLKFBOUT_MULT   = 15,     // VCO = 50MHz * 15 = 750MHz (7-series -1: 600-1200MHz range)
    parameter CLKOUT0_DIVIDE  = 5       // clk_h = 750MHz / 5 = 150MHz -- see note above
)
(
    input  wire clk_in,     // from sys_clk_50m (via IBUF upstream)
    input  wire rst,        // async reset, active high
    output wire clk_h,      // hash-core clock
    output wire clk_h_locked
);

    wire clkfb;
    wire clkout0_unbuf;

    MMCME2_BASE #(
        .BANDWIDTH        ("OPTIMIZED"),
        .CLKFBOUT_MULT_F  (CLKFBOUT_MULT),
        .CLKFBOUT_PHASE   (0.0),
        .CLKIN1_PERIOD    (CLKIN_PERIOD_NS),
        .CLKOUT0_DIVIDE_F (CLKOUT0_DIVIDE),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE    (0.0),
        .DIVCLK_DIVIDE    (1),
        .REF_JITTER1      (0.010),
        .STARTUP_WAIT     ("FALSE")
    ) mmcm_inst (
        .CLKIN1   (clk_in),
        .CLKFBIN  (clkfb),
        .CLKFBOUT (clkfb),
        .CLKOUT0  (clkout0_unbuf),
        .PWRDWN   (1'b0),
        .RST      (rst),
        .LOCKED   (clk_h_locked)
    );

    BUFG bufg_clk_h (
        .I (clkout0_unbuf),
        .O (clk_h)
    );

endmodule
