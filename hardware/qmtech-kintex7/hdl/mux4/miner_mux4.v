// miner_mux4.v -- the clk2x/phase-carrying variants, for the 4-INSTANCE
// shared-BRAM experiment ONLY.
//
// SEPARATE FILES ON PURPOSE. The shipping RTL is untouched by this experiment:
// hdl/odocrypt/miner.v, miner_pipelined.v, ../odocrypt_gpio_wrapper.v and
// ../am01_qmtech_top.v are all left exactly as they are, because a 200MHz
// bitstream built from them is flashed and earning right now. Everything the
// experiment needs that differs lives here, in hdl/mux4/, and is only ever
// pulled in by build_mux4.tcl.
//
// WHAT THE EXPERIMENT IS. tools/mux2_transform.py collapses each PAIR of large
// S-box slots that read the same table into ONE block RAM, time-multiplexed on
// a 2x clock. Per instance that is 420 -> 210 RAMB18, so FOUR instances fit in
// the 890 the XC7K325T has, where two fit today.
//
//   stock   2 instances x 420 RAMB18 = 840 (94%)
//   mux2    4 instances x 210 RAMB18 = 840 (94%)
//
// WHAT IT COSTS, AND WHY THIS IS AN EXPERIMENT RATHER THAN AN UPGRADE. Every
// path INTO a time-multiplexed memory has to close in one clk2x period. At
// clk_h = 200MHz that is 2.5ns, and routing alone on a BRAM-adjacent path in
// the shipping build measures 3.201ns of a 4.055ns total. So clk_h has to fall
// for clk2x to close, and the design trades clock for instances. Prior work
// measured 1.22x overall; my own arithmetic off the current build lands near
// 1.4x. Neither has ever been measured under Vivado -- openXC7 cannot time
// paths adjacent to a block RAM at all (see openxc7/README.md), which is
// exactly what this question is. That gap is the reason to run it.
//
// The transform gives encrypt_4encrypt two extra ports (clk2x, phase). This
// file carries them the rest of the way up: odo_keccak -> miner_pipelined.
//
// NOT USED WITH --bram-out-reg. sbox_large_mux2 is a drop-in for the ONE-cycle
// S-box, and --bram-out-reg makes it two. Combining them needs a third pipeline
// stage inside the muxed module and a matching RoundCycles, which is a separate
// change; this experiment answers the routability question first, because that
// is what has killed every previous attempt at more instances.

`ifndef THROUGHPUT
`define THROUGHPUT 4
`endif

// odo_keccak with the 2x clock threaded through to the encrypt core.
// cmp_256 and keccak_hasher are NOT redefined -- miner.v is compiled alongside
// and owns them, so there is exactly one of each in the build.
module odo_keccak_mux4(clk, clk2x, phase, in, read, target, out, write);
	input clk;
	input clk2x;
	input phase;
	input [639:0] in;
	input read;
	input [255:0] target;
	output out;
	output write;

	wire [639:0] midstate;
	wire midread;
	wire [255:0] pow_hash;
	wire has_hash;

	encrypt_4encrypt crypt(clk, clk2x, phase, in, read, midstate, midread);
	keccak_hasher #(640, `THROUGHPUT) hash(clk, midstate, midread, pow_hash, has_hash);
	cmp_256 compare(clk, pow_hash, has_hash, target, out, write);
endmodule

// miner_pipelined with clk2x/phase added. Body is otherwise character-for-
// character hdl/odocrypt/miner_pipelined.v -- including the property that
// makes any of this safe: nonce_in and nonce_out are initialised ONCE and
// free-run, so the Nth result pairs with the Nth input BY COUNTING. Pipeline
// depth is irrelevant to correctness, which is why a transform that changes
// the core's latency does not need anything here to be re-derived.
module miner_pipelined_mux4(clk, clk2x, phase, header, target, nonce, found);
    parameter INONCE = 0;

    input clk;
    input clk2x;
    input phase;
    input [607:0] header;
    input [255:0] target;
    output reg [31:0] nonce;
    output reg found;

    reg [31:0] nonce_in;
    reg [31:0] nonce_out;
    initial nonce_in = INONCE;
    initial nonce_out = INONCE;

    reg [6:0] counter;
    reg advance;
    initial counter = `THROUGHPUT-1;
    initial advance = 0;
    initial found = 0;

    wire res;
    wire has_res;

    odo_keccak_mux4 worker(clk, clk2x, phase, {nonce_in, header}, advance,
                           target, res, has_res);

    always @(posedge clk)
    begin
        if (counter == `THROUGHPUT-1)
        begin
            counter <= 0;
            advance <= 1;
        end
        else
        begin
            counter <= counter + 1;
            advance <= 0;
        end
        if (advance)
            nonce_in <= nonce_in + 1;
        found <= 1'b0;
        if (has_res)
        begin
            if (res)
            begin
                nonce <= nonce_out;
                found <= 1'b1;
            end
            nonce_out <= nonce_out + 1;
        end
    end
endmodule
