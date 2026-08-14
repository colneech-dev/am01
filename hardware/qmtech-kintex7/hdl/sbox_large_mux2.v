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
// STATUS: prototype, MEASURED, and the result is a partial win with a
// hard architectural ceiling. Read this before building on it.
//
// Bit-exactness holds: the transformed encrypt core is identical to the
// stock one over 493 defined cycles, with a negative control that fails
// 473/473 (../sim/tb_encrypt_equiv.v). Block RAM halves exactly as
// intended, 420 -> 210 RAMB18 per hash instance, so 4 instances fit in
// the 890 available where 2 fit before.
//
// But place-and-route of the real muxed miner gives clk_2x = 103.72 MHz,
// not the ~160 MHz an isolated S-box probe suggested. Net effect:
//
//   stock       2 instances @ 84.90 MHz clk_h  = 42.5 MH/s
//   shared-BRAM 4 instances @ 51.86 MHz clk_h  = 51.9 MH/s   (1.22x)
//
// WHY IT FALLS SHORT, AND WHY THAT IS STRUCTURAL
// ---------------------------------------------
// The S-box address settles about 9.6 ns into an 11.78 ns clk_h period.
// The stock design samples it on the NEXT clk_h edge, so it gets the
// whole period. Time multiplexing forces slot 0 to sample half a period
// early, at 5.888 ns -- before the address is ready. Slot 1 still samples
// on the clk_h edge and is fine.
//
// NOTE (corrected): an earlier revision of this comment attributed that
// 9.6 ns to "combinational logic from the previous pipeline stage". It is
// not logic. encrypt_4apply_pbox0 is 640 plain `assign out[j] = in[i];`
// statements -- zero operators -- so the address is a pure permutation of
// state[i], a flip-flop output, at ZERO logic levels. The 9.6 ns is
// ROUTING: a 640-bit die-crossing shuffle from one round's state
// registers to that round's 20 block RAMs, in a build with no
// floorplanning at all. That reframes the ceiling as placement rather
// than pipeline structure -- see ../HASHRATE-REVIEW.md §3, and
// ../vivado/report_sbox_paths.tcl which measures it. It also explains why
// mux2_pipelined_transform.py made timing WORSE rather than better:
// adding registers to a congestion-bound design pushes endpoints apart.
//
// The same place-and-route reports muxed clk_h = 161.29 MHz against the
// stock design's 84.90. That is the tell: the long path did not get
// faster, it MOVED into the clk_2x domain, where half the time is
// available. An isolated probe misses this entirely because it drives
// addresses straight from a flop.
//
// Fixing it means registering the S-box address, which costs a full clk_h
// of latency on every S-box -- i.e. regenerating encrypt.v with different
// pipelining, not a drop-in transform. Phase-shifting clk_2x does not
// rescue it either: giving the address more time leaves under 2.2 ns
// between the two reads, and block RAM clock-to-out alone is 2.454 ns.
//
// Still unverified on hardware.
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
