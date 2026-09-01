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
// Emits TWO phase-aligned clocks from one MMCM:
//
//   clk_h   -- the hash-core clock, as before
//   clk_2x  -- exactly 2 x clk_h, for the shared-BRAM S-boxes in
//              sbox_large_mux2.v / the mux2 transform
//
// Both come off the same MMCM with CLKOUTn_PHASE 0.0, so they are
// phase-aligned by construction. That is what makes the S-box time
// multiplexing synchronous multi-rate logic rather than a clock-domain
// crossing -- no synchronisers, no metastability. Nothing else in the
// design may generate clk_2x, or that guarantee is gone.
//
// WHY THE FREQUENCIES CHANGED (150 -> 133.33MHz nominal)
// ------------------------------------------------------
// The 2x pair has to be two *integer* MMCM output dividers in a 2:1
// ratio. From the old VCO of 750MHz the only integer pairs available were
// 3/6 (250/125MHz) and 2/4 (375/187.5MHz); 750/2.5 = 300MHz would work
// arithmetically but only via CLKOUT0's fractional divider, which costs
// duty-cycle accuracy and adds jitter on the very clock the block RAMs
// run on. Raising the VCO to 800MHz (MULT 16, still inside the -1 grade's
// 600-1200MHz range) gives the clean integer pair 3/6 = 266.67/133.33MHz.
//
// Dropping the nominal from 150 to 133.33MHz costs nothing real: the old
// 150 was never verified on this part. It came from a cross-vendor
// comparison with colneech-dev/odo-miner-cyclonev, where Quartus reported
// Fmax = 162.1MHz for the same upstream THROUGHPUT=4 core on a Cyclone V.
// The first actual measurement on THIS XC7K325T-1FFG676C came back at
// clk_h = 135.04MHz -- the Kintex-7 clocks *lower* than the Cyclone V for
// this design, not higher. 133.33MHz sits just under that measurement, so
// this is the first setting here grounded in a number from this part
// rather than from another vendor's.
//
// STATUS: clk_2x at 2x clk_h has NOT been shown to close timing on real
// place-and-route. The block RAM itself has margin (ds182 rates FMAX_BRAM
// at 458MHz for -1), so the path to watch is the address muxing in
// sbox_large_mux2, not the memory. Moot at present: nothing consumes
// clk_2x, synthesis drops its BUFG, and it appears in no clock table.
//
// SPEED BUMP, 2026-09-01: MULT 16 -> 19, clk_h 133.33 -> 158.33MHz (+18.75%).
//
// Grounded in a measurement rather than a guess. The 0x0202 build closed at
// WNS +1.398ns against a 7.500ns period, so the worst path takes 6.102ns and
// the design is good for at least 163.9MHz. "At least" is the important part:
// the tool stops optimising once it meets the constraint, so 163.9 is a lower
// bound, and constraining tighter usually buys more.
//
//   MULT 18 -> 150.00MHz, 6.667ns, predicted slack +0.565ns
//   MULT 19 -> 158.33MHz, 6.316ns, predicted slack +0.214ns   <- chosen
//   MULT 20 -> 166.67MHz, 6.000ns, predicted slack -0.102ns   would fail
//
// VCO 950MHz is inside the -1 grade's 600-1200MHz range. bus_clk is
// sys_clk_50m straight through and is NOT affected, so uart_bridge's
// CLK_HZ=50_000_000 and the fan PWM divider stay correct -- worth stating
// because a clock change that silently rebaudsthe panel would be found late.
//
// If this does not close, fall back to MULT 18 before anything else: it is
// still +12.5% and has more than twice the predicted margin.
//
`timescale 1ns / 1ps

module clk_gen_hash #(
    parameter CLKIN_PERIOD_NS = 20.000, // 50MHz input
    parameter CLKFBOUT_MULT   = 19,     // VCO = 50MHz * 19 = 950MHz (7-series -1: 600-1200MHz range)
    parameter CLKOUT_DIVIDE_2X = 3      // clk_2x = 950/3 = 316.67MHz, clk_h = 950/6 = 158.33MHz
)
(
    input  wire clk_in,     // from sys_clk_50m (via IBUF upstream)
    input  wire rst,        // async reset, active high
    output wire clk_h,      // hash-core clock
    output wire clk_2x,     // 2 x clk_h, phase aligned -- shared-BRAM S-boxes
    output wire clk_h_locked
);

    // clk_h is derived by doubling the clk_2x divider, so the 2:1 ratio
    // cannot drift if someone retunes CLKOUT_DIVIDE_2X.
    localparam CLKOUT_DIVIDE_H = 2 * CLKOUT_DIVIDE_2X;

    wire clkfb;
    wire clkout0_unbuf;   // clk_2x
    wire clkout1_unbuf;   // clk_h

    MMCME2_BASE #(
        .BANDWIDTH        ("OPTIMIZED"),
        .CLKFBOUT_MULT_F  (CLKFBOUT_MULT),
        .CLKFBOUT_PHASE   (0.0),
        .CLKIN1_PERIOD    (CLKIN_PERIOD_NS),
        .CLKOUT0_DIVIDE_F (CLKOUT_DIVIDE_2X),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE    (0.0),
        .CLKOUT1_DIVIDE   (CLKOUT_DIVIDE_H),
        .CLKOUT1_DUTY_CYCLE(0.5),
        .CLKOUT1_PHASE    (0.0),
        .DIVCLK_DIVIDE    (1),
        .REF_JITTER1      (0.010),
        .STARTUP_WAIT     ("FALSE")
    ) mmcm_inst (
        .CLKIN1   (clk_in),
        .CLKFBIN  (clkfb),
        .CLKFBOUT (clkfb),
        .CLKOUT0  (clkout0_unbuf),
        .CLKOUT1  (clkout1_unbuf),
        .PWRDWN   (1'b0),
        .RST      (rst),
        .LOCKED   (clk_h_locked)
    );

    BUFG bufg_clk_2x (
        .I (clkout0_unbuf),
        .O (clk_2x)
    );

    BUFG bufg_clk_h (
        .I (clkout1_unbuf),
        .O (clk_h)
    );

endmodule
