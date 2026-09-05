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

// EXTRACTED from hdl/odocrypt/miner.v by make_mux4_variants.py.
//
// cmp_256 alone, because the mux4 build cannot compile miner.v: its
// odo_keccak instantiates encrypt_4encrypt with five ports and the
// muxed core has seven. Nothing here is modified.

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
