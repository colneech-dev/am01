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
//   MULT 19 -> 158.33MHz, 6.316ns, predicted slack +0.214ns
//   MULT 20 -> 166.67MHz, 6.000ns, predicted slack -0.102ns   predicted fail
//
// SECOND BUMP, 2026-09-05: MULT 19 -> 24, clk_h 158.33 -> 200.00MHz (+26.3%).
// Hashrate 2 * 200 / 4 = 100.0 MH/s, up from 79.2.
//
// This catches the file up with reality rather than proposing anything new: a
// MULT 24 / 200MHz bitstream is ALREADY built, flashed and earning
// (vivado/artifacts/am01_VER0x0203_200.00MHz_epoch1788480000_OUTREG_MULT24.bit,
// per build_mux4.tcl's header). The parameter here was simply never committed
// alongside it, so the repo said 158.33MHz while the board ran 200MHz.
//
// THE PREDICTION ABOVE WAS WRONG, and the way it was wrong matters. It
// extrapolated from a FIXED 6.102ns worst path (the 0x0202 build's 7.500ns
// period minus its +1.398ns WNS) and concluded MULT 20 fails by -0.102ns. But
// that path length was itself a product of a loose constraint: Vivado stops
// optimising once it meets the target, so a path measured under 7.500ns says
// nothing about what the same design does when asked for 6.000ns. Constraining
// tighter really does buy more, exactly as the note above suspected.
//
// Measured, not predicted -- post-route Design Timing Summary, all with
// TNS 0.000 and ZERO failing endpoints of 75076 (86478 for the OUTREG pair):
//
//   MULT 20        166.67MHz   WNS +0.508ns   (predicted to FAIL at -0.102)
//   MULT 20.5      170.83MHz   WNS +0.427ns
//   MULT 21        175.00MHz   WNS +0.194ns
//   MULT 22 OUTREG 183.33MHz   WNS +0.930ns
//   MULT 24 OUTREG 200.00MHz   WNS +0.763ns   <- chosen, and already flashed
//
// The first three rows are the pre-OUTREG core and are kept only for the
// comparison. The OUTREG rows are the core this repo actually ships:
// hdl/odocrypt/encrypt.v is generated `--bram-out-reg`, whose extra pipeline
// stage (BRAM DO_REG buys clock-to-out 2.454ns -> 0.882ns) breaks the critical
// path. That is why 200MHz there carries FOUR TIMES the margin of 175MHz on
// the plain core, and why 200MHz rather than 175MHz is the right setting.
//
// Throughput is not traded away for that latency: rounds go 2 -> 3 cycles and
// latency 171 -> 252, but THROUGHPUT is clocks-per-hash (keccak800.v:188),
// fixed at 4 by miner.v:18, and `write` is self-reported via
// progress[latency-1]. The deeper pipeline just holds more work in flight.
// See openxc7/AUDIT-BUILT-VS-TESTED.md, "Throughput is NOT lost".
//
// MULT 24 IS THE CEILING for this divider arrangement, not a free choice:
// VCO = 50 * 24 = 1200MHz is exactly the -1 grade's maximum. MULT 25 would ask
// for 1250MHz and is out of spec. Going faster would need CLKOUT_DIVIDE_2X = 2
// (clk_h = VCO/4 = 300MHz), which puts clk_2x at 600MHz -- impossible. So
// 200MHz is the end of the road for clk_h here; more hashrate has to come from
// more instances, which is what the mux4 experiment is for.
//
// +0.763ns at 200MHz is 15.3% of the 5.000ns period, and hold is fine (WHS
// +0.032ns). If a board proves marginal, MULT 22 gives back 16.7MHz for
// slightly MORE margin (+0.930ns).
//
// VCO = 50 * 24 = 1200MHz, the -1 grade's maximum. clk_2x
// becomes 400MHz but nothing consumes it (synthesis drops its BUFG), and
// bus_clk is still sys_clk_50m straight through, so the UART baud and fan PWM
// divider are untouched.
//
// (Of the 2026-09-01 bump, superseded above: its VCO was 950MHz, and its
// fallback advice was MULT 18. Both are obsolete now that MULT 20-24 have
// been measured rather than extrapolated -- fall back per the measured table,
// not to MULT 18.)
//
// The bus_clk point from that bump still holds and is worth repeating: bus_clk
// is sys_clk_50m straight through and is NOT affected by any MULT change, so
// uart_bridge's CLK_HZ=50_000_000 and the fan PWM divider stay correct. A
// clock change that silently rebauds the panel would otherwise be found late.
//
`timescale 1ns / 1ps

module clk_gen_hash #(
    parameter CLKIN_PERIOD_NS = 20.000, // 50MHz input
    parameter CLKFBOUT_MULT   = 24,     // VCO = 50MHz * 24 = 1200MHz (7-series -1: 600-1200MHz range)
    parameter CLKOUT_DIVIDE_2X = 3      // clk_2x = 1200/3 = 400.00MHz, clk_h = 1200/6 = 200.00MHz
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
