// Copyright (C) 2019 MentalCollatz
// Copyright (C) 2019-2022 AtomMiner LLC
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
`timescale 1ns / 1ps

`define  THROUGHPUT 4

module cmp_256(clk, in, read, target, out, write);
	input clk;
	input [255:0] in;
	input read;
	input [255:0] target;
	output reg out = 1'b0;
	output reg write;
	
	reg [15:0] greater = 16'h0, less = 16'h0;
	reg progress;
									reg read_r = 1'b0;
	initial progress = 0;
	initial write = 0;
	
	genvar i;
	generate
	for (i = 0; i < 16; i = i+1)
	begin : loop
		always @(posedge clk)
		begin
			greater[i] <= (in[16*i+15:16*i] > target[16*i+15:16*i]);
			less[i] <= (in[16*i+15:16*i] < target[16*i+15:16*i]);
		end
	end
	endgenerate
	
	always @(posedge clk) read_r <= read;
	always @(posedge clk) if (read_r)  out <= (greater < less); else out <= 1'b0;
	
	always @(posedge clk)
	begin
		progress <= read;
		write <= progress;
	end
endmodule

module odo_keccak(clk, in, read, target, out, write);
	input clk;
	input [639:0] in;
	input read;
	input [255:0] target;
	output out; //ticket2moon
	output write;

	wire [639:0] midstate;
	wire midread;
	wire [255:0] pow_hash;
	wire has_hash;

	encrypt_4encrypt crypt(clk, in, read, midstate, midread);
	keccak_hasher #(640, `THROUGHPUT) hash(clk, midstate, midread, pow_hash, has_hash);
	cmp_256 compare(clk, pow_hash, has_hash, target, out, write);
endmodule

// ---------------------------------------------------------------------
// `miner` and `miner_top` WERE HERE. REMOVED 2026-09-09.
//
// They were the AtomMiner core that VERSION 0x0200 replaced with
// miner_pipelined, and nothing had instantiated either of them since. The
// replacement's own header records why they went:
//
//     "three separate faults were found and fixed in miner.v (arming
//      wraparound 0x0106, too-short settle window 0x0107, nonce_out gated on
//      nonce_out_go 0x0108) plus a fourth in the wrapper ... 16/16 results
//      reported the WRONG NONCE (cipher correct, nonce_out wrong, by an
//      inconsistent offset each time)"
//
// So this file was carrying a core KNOWN to mislabel nonces -- compiled into
// every build, one instantiation away from being used by mistake -- during the
// two days spent chasing a nonce-mislabelling fault in the core that replaced
// it. Removed rather than commented out: git has it, and the point is that it
// should not be reachable.
//
// cmp_256 and odo_keccak above are the parts actually used, by
// miner_pipelined.v and by tools/make_mux4_variants.py, and are untouched.
// The upstream provenance recorded in NOTICE is unaffected.
