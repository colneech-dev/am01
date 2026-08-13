`timescale 1ns/1ps
//
// Equivalence: the stock OdoCrypt encrypt core vs the shared-BRAM rewrite
// produced by ../tools/mux2_transform.py.
//
// Both cores are instantiated in ONE simulation and driven from the same
// stimulus, so the verdict cannot be an artefact of two processes, file
// buffering, or a run that was cut short. (An earlier version of this
// test *was* two processes diffing two files, and a container restart
// left both files holding nothing but a partial buffer of all-X. The
// diff would have "matched".)
//
// TWO THINGS THIS TEST HAS TO GET RIGHT
// -------------------------------------
// 1. The encrypt pipeline is 172 stages deep -- see
//        assign write = progress[171];
//    in encrypt.v. `out` is legitimately all-X until ~cycle 172, so a
//    naive full-run diff compares X against X and passes while proving
//    nothing. This test only counts cycles where the *reference* output
//    is fully defined, and reports INCONCLUSIVE rather than PASS if
//    fewer than MIN_DEFINED such cycles accumulate.
//
// 2. A test that passes at both interleave phases is not testing the
//    interleave. Run it with +pinv=1 to invert the phase: that run MUST
//    fail. If it passes, the testbench is insensitive and the +pinv=0
//    pass is meaningless.
//
// Usage: see run_encrypt_equiv.sh, which regenerates the muxed core and
// runs both polarities. ~2.7 s per simulated cycle here, so a 600-cycle
// run is roughly half an hour.
//
module tb;
    localparam N           = 600;  // clk_h cycles of stimulus
    localparam MIN_DEFINED = 100;  // refuse to declare PASS below this

    // clk2x is the real clock; clk_h and phase are both derived from it in
    // the non-blocking region so every sampler sees a consistent
    // pre-update value. This is what an MMCM gives you -- phase-aligned
    // multi-rate clocks, NOT a clock-domain crossing.
    reg clk2x = 0;
    always #2.5 clk2x = ~clk2x;

    reg clk_h = 0;
    reg phase = 1;                 // phase==0 while clk_h is high
    integer pinv = 0;
    always @(posedge clk2x) begin
        clk_h <= ~clk_h;
        phase <= ~phase;
    end
    wire phase_d = pinv ? ~phase : phase;

    reg [639:0] in;
    reg         read = 0;

    wire [639:0] out_ref,   out_mux;
    wire         write_ref, write_mux;

    encrypt_4encrypt    u_ref (clk_h, in, read, out_ref, write_ref);
    mx_encrypt_4encrypt u_mux (clk_h, clk2x, phase_d, in, read, out_mux, write_mux);

    integer i;
    integer n_def     = 0;   // cycles where the reference output was defined
    integer n_cmp     = 0;   // cycles actually compared
    integer n_bad     = 0;   // data mismatches
    integer n_wbad    = 0;   // write-strobe mismatches
    integer first_def = -1;

    initial begin
        if (!$value$plusargs("pinv=%d", pinv)) pinv = 0;
        in = 640'h0; read = 0;
        repeat (4) @(posedge clk_h);

        for (i = 0; i < N; i = i + 1) begin
            @(negedge clk_h);
            in = {$random,$random,$random,$random,$random,
                  $random,$random,$random,$random,$random,
                  $random,$random,$random,$random,$random,
                  $random,$random,$random,$random,$random};
            read = (i % 4 == 0);   // THROUGHPUT=4: one new block every 4 cycles

            @(posedge clk_h);
            #1;                    // let the NBA region settle before sampling

            if (write_ref !== write_mux) begin
                n_wbad = n_wbad + 1;
                if (n_wbad <= 5)
                    $display("  WRITE MISMATCH cycle %0d: ref=%b mux=%b",
                             i, write_ref, write_mux);
            end

            // ^out_ref reduces to 1'bx if ANY bit of out_ref is x or z.
            if (^out_ref !== 1'bx) begin
                n_def = n_def + 1;
                if (first_def < 0) first_def = i;
                n_cmp = n_cmp + 1;
                if (out_ref !== out_mux) begin
                    n_bad = n_bad + 1;
                    if (n_bad <= 5)
                        $display("  DATA MISMATCH cycle %0d:\n    ref=%h\n    mux=%h",
                                 i, out_ref, out_mux);
                end
            end
        end

        $display("");
        $display("=== encrypt core: original vs shared-BRAM (2x muxed) ===");
        $display("  phase polarity         : %0d%s", pinv,
                 pinv ? " (CONTROL -- must FAIL)" : " (intended)");
        $display("  clk_h cycles driven    : %0d", N);
        $display("  first defined output   : cycle %0d", first_def);
        $display("  defined cycles compared: %0d", n_cmp);
        $display("  data mismatches        : %0d", n_bad);
        $display("  write-strobe mismatches: %0d", n_wbad);
        // NB: do not collapse these into $display(cond ? "A" : "B") --
        // Verilog treats the two string literals as numeric vectors of
        // differing width and prints a long integer instead of a verdict.
        if (n_cmp < MIN_DEFINED)
            $display("  RESULT: INCONCLUSIVE -- only %0d defined cycles (need %0d); pipeline never filled",
                     n_cmp, MIN_DEFINED);
        else if (n_bad == 0 && n_wbad == 0)
            $display("  RESULT: PASS -- bit-identical over %0d defined cycles", n_cmp);
        else
            $display("  RESULT: FAIL");
        $finish;
    end
endmodule
