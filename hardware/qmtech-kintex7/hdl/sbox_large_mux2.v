//////////////////////////////////////////////////////////////////////////////////
/*
 *  AtomMiner AM01 -- QMTECH Kintex-7 + Raspberry Pi CM4 variant
 *
 *  Copyright 2015-2022 AtomMiner <atom@atomminer.com>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation; either version 3 of the License, or (at your option)
 * any later version. If not, see <http://www.gnu.org/licenses/>.
 */
//////////////////////////////////////////////////////////////////////////////////
//
// sbox_large_mux2 -- two OdoCrypt large S-boxes sharing ONE block RAM by
// time-multiplexing its ports on a 2x clock.
//
// WHY
// ---
// The hash core is BRAM-bound, not logic-bound. One instance needs 420
// RAMB18 of the XC7K325T's 890, so only 2 instances fit (94% BRAM) while
// 61% of the LUTs sit idle. See ../README.md "Expected hashrate".
//
// But the block RAM is also idle most of the time: on this -1 speed grade
// it is rated FMAX_BRAM = 458 MHz (ds182) while the hash core measures
// clk_h = 135 MHz. The two ports are therefore underused *in time* by
// ~3.4x, not just limited in number.
//
// Clocking the BRAM at 2x clk_h and interleaving gives 4 logical read
// ports per hash cycle out of the same 2 physical ports -- enough for two
// S-boxes. BRAM per instance halves (420 -> 210) and 4 instances fit
// instead of 2.
//
// HOW
// ---
// The original S-box is a plain registered ROM read:
//
//     always @(posedge clk) begin
//         a_out <= mem[a_in];
//         b_out <= mem[b_in];
//     end
//
// Here, on clk2x (2x clk_h, phase-aligned, same MMCM):
//
//     phase 0 : drive port A with s0_a_in, port B with s0_b_in
//     phase 1 : drive port A with s1_a_in, port B with s1_b_in
//
// and each result is captured into that S-box's output register. Both
// outputs therefore land within one clk_h period, so **latency stays 1
// clk_h cycle** and the surrounding pipeline is unchanged -- this is a
// drop-in replacement for two sbox instances, not a pipeline change.
//
// Because clk2x is derived from the same MMCM and phase-aligned to clk_h,
// this is synchronous multi-rate logic, NOT a clock-domain crossing: no
// synchronisers, no metastability. The one real constraint is that clk2x
// (270 MHz at today's 135 MHz clk_h) must close timing on the address
// muxing below. The BRAM itself has margin (458 MHz rated); the muxes are
// the thing to watch.
//
// PHASE CONVENTION
// ----------------
// `phase` is asserted for the clk2x cycle that aligns with clk_h low, and
// is generated once per design (not per S-box) so every muxed S-box
// interleaves identically -- see sbox_mux_phase_gen at the bottom.
//
// STATUS: prototype. Simulation-verified bit-exact against two
// independent sbox instances (see ../sim/tb_sbox_mux2.v). NOT yet timed
// at 270 MHz on real place-and-route, and not run on hardware.
//
`timescale 1ns / 1ps

module sbox_large_mux2 #(
    // Contents of the ROM. Both S-boxes share the same table only if
    // SAME_TABLE=1; otherwise this module is instantiated once per
    // *pair of S-box slots that use the same table*. OdoCrypt has 10
    // distinct large tables (sbox_large0..9) replicated across encrypt
    // blocks, so pairing two users of the same table is the natural fit
    // and needs no extra storage.
    parameter INIT_FILE = "",
    parameter integer AW = 10,   // address width (1024 entries)
    parameter integer DW = 10    // data width
) (
    input  wire            clk2x,      // 2 x clk_h, phase aligned, same MMCM
    input  wire            phase,      // 0 = serve S-box 0, 1 = serve S-box 1

    // S-box slot 0 -- identical interface to encrypt_4sbox_largeN
    input  wire [AW-1:0]   s0_a_in,
    input  wire [AW-1:0]   s0_b_in,
    output reg  [DW-1:0]   s0_a_out,
    output reg  [DW-1:0]   s0_b_out,

    // S-box slot 1
    input  wire [AW-1:0]   s1_a_in,
    input  wire [AW-1:0]   s1_b_in,
    output reg  [DW-1:0]   s1_a_out,
    output reg  [DW-1:0]   s1_b_out
);

    // The shared table. One physical RAMB18 (1024 x 10 = 10,240 bits of
    // an 18,432-bit block), dual-ported, now serving four logical reads
    // per clk_h period instead of two.
    (* ram_style = "block" *)
    reg [DW-1:0] mem [0:(1<<AW)-1];

    initial if (INIT_FILE != "") $readmemh(INIT_FILE, mem);

    // ---- Address muxing: which slot owns the ports this clk2x cycle ----
    wire [AW-1:0] a_addr = phase ? s1_a_in : s0_a_in;
    wire [AW-1:0] b_addr = phase ? s1_b_in : s0_b_in;

    // ---- The two physical BRAM ports ----
    reg [DW-1:0] a_q, b_q;
    always @(posedge clk2x) begin
        a_q <= mem[a_addr];
        b_q <= mem[b_addr];
    end

    // ---- Demux the results back to their owning slot ----
    // a_q/b_q are valid one clk2x cycle after the address was presented,
    // so the phase that *issued* the read is the delayed phase.
    reg phase_q;
    always @(posedge clk2x) phase_q <= phase;

    always @(posedge clk2x) begin
        if (!phase_q) begin
            s0_a_out <= a_q;
            s0_b_out <= b_q;
        end else begin
            s1_a_out <= a_q;
            s1_b_out <= b_q;
        end
    end

endmodule


// Generates the interleave phase for every muxed S-box in the design.
// Instantiate ONCE and fan out. Reset-aligned so all muxed S-boxes agree
// on which clk2x cycle belongs to slot 0.
module sbox_mux_phase_gen (
    input  wire clk2x,
    input  wire rst_n,
    output reg  phase
);
    always @(posedge clk2x or negedge rst_n)
        if (!rst_n) phase <= 1'b0;
        else        phase <= ~phase;
endmodule
