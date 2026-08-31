// miner_pipelined.v -- adopted from odo-miner-cyclonev's
// hdl/src/pipelined/odo_miner_core.v (module `miner`), renamed to avoid
// colliding with our own hdl/odocrypt/miner.v `miner` module -- both are kept
// so an A/B swap in the wrapper is a one-line change, not a deletion.
//
// WHY: three separate faults were found and fixed in miner.v (arming
// wraparound 0x0106, too-short settle window 0x0107, nonce_out gated on
// nonce_out_go 0x0108) plus a fourth in the wrapper (golden_nonce_h latched
// one cycle late, 0x0109). All four are symptoms of the same root cause:
// nonce_in/nonce_out RESET TO NONCE_BASE on every halt in miner.v, so every
// single re-arm (which happens on EVERY find, since the AtomMiner core halts
// on found -- not just on every new pool job) restarts the settle/warm-up
// dance from zero. Confirmed on hardware 2026-08-31 via a header-cycling
// am01_smoke run: 16/16 results reported the WRONG nonce (cipher correct,
// nonce_out wrong, by an inconsistent offset each time) the moment each
// dispatch explored genuinely fresh nonce territory instead of deterministically
// replaying an already-proven-good sequence.
//
// This module has none of that: nonce_in/nonce_out are `initial`-ized ONCE
// and free-run forever from power-on. There is no start_hash, no halt, no
// re-arm, and therefore no reset-to-zero-then-resettle dance to get wrong.
// The Nth result pairs with the Nth input by construction, always.
//
// Reuses the odo_keccak module already defined in miner.v (same file is
// always compiled alongside this one) -- not redefined here, so there is
// exactly one cmp_256/odo_keccak in the build, and it is OUR version (with
// the read_r-guarded cmp_256 comparator, not upstream's unguarded one).
//
// DIVERGENCE FROM UPSTREAM (odo-miner-cyclonev, and in turn odo-miner
// upstream, both GPLv3, (C) 2019 MentalCollatz):
//   - module renamed miner -> miner_pipelined
//   - does not declare cmp_256/odo_keccak/keccak_hasher itself; relies on
//     miner.v's definitions being present in the same compile
//   - comments above are new; everything else is unchanged from
//     odo-miner-cyclonev's odo_miner_core.v `miner` module

// miner.v defines THROUGHPUT too, and both must agree -- they wrap the same
// odo_keccak. Guarded rather than assumed, because `define propagation across
// files is compile-ORDER dependent (Vivado adds files to a fileset, iverilog
// takes them in argv order), and a file that silently picks up a stale value
// for its pipeline depth would be a very quiet way to get a wrong hash.
// If miner.v's value ever changes, change it here too.
`ifndef THROUGHPUT
`define THROUGHPUT 4
`endif

module miner_pipelined(clk, header, target, nonce, found);
    parameter INONCE = 0; // NONCE_BASE for this instance, same convention as
                           // miner.v's NONCE_BASE

    input clk;
    input [607:0] header;
    input [255:0] target;
    output reg [31:0] nonce;
    // 1-cycle strobe, asserted on the same edge `nonce` latches a qualifying
    // nonce. Lets the wrapper push EVERY find exactly once into a FIFO
    // instead of inferring finds from a change in `nonce` (which loses a
    // find whenever a new winner equals the value already latched, or when
    // the FIFO is full).
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

    odo_keccak worker(clk, {nonce_in, header}, advance, target, res, has_res);

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
        found <= 1'b0;            // default: one-cycle pulse
        if (has_res)
        begin
            if (res)
            begin
                nonce <= nonce_out;
                found <= 1'b1;   // qualifying nonce latched this edge
            end
            nonce_out <= nonce_out + 1;
        end
    end
endmodule
