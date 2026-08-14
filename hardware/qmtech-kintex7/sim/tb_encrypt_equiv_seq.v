`timescale 1ns/1ps
//
// Equivalence for a transform that CHANGES PIPELINE DEPTH.
//
// tb_encrypt_equiv.v compares the two cores cycle by cycle, which only
// works while they have identical latency. The pipelined shared-BRAM
// transform (tools/mux2_pipelined_transform.py) deepens each round by 2
// clk_h, moving `write` from progress[171] to progress[339]. A
// cycle-aligned diff would then report 100% mismatch on a core that is
// perfectly correct.
//
// So this compares the SEQUENCE of emitted results instead: every time a
// core asserts `write`, its output word is pushed onto that core's queue,
// and the queues are compared element by element. Latency drops out;
// order and content do not.
//
// The negative control still applies: +pstuck=1 holds the interleave
// phase constant so S-box slot 1 is never serviced. That must FAIL, or
// the test cannot detect broken hardware and a pass means nothing.
//
module tb;
    localparam N        = 900;   // clk_h cycles (deep pipeline needs them)
    localparam MIN_SEQ  = 20;    // refuse to pass on fewer than this many results
    localparam MAXQ     = 4096;

    reg clk2x = 0;
    always #2.5 clk2x = ~clk2x;

    reg clk_h = 0;
    reg phase = 1;
    integer pinv = 0, pstuck = 0;
    always @(posedge clk2x) begin
        clk_h <= ~clk_h;
        phase <= ~phase;
    end
    wire phase_t = pinv ? ~phase : phase;
    wire phase_d = pstuck ? 1'b0 : phase_t;

    reg [639:0] in;
    reg         read = 0;

    wire [639:0] out_ref,   out_mux;
    wire         write_ref, write_mux;

    encrypt_4encrypt    u_ref (clk_h, in, read, out_ref, write_ref);
    mx_encrypt_4encrypt u_mux (clk_h, clk2x, phase_d, in, read, out_mux, write_mux);

    reg [639:0] qref [0:MAXQ-1];
    reg [639:0] qmux [0:MAXQ-1];
    integer nref = 0, nmux = 0;
    integer i, k, nbad = 0, ncmp = 0;

    // Queue every emitted result. Sampling on the negedge keeps this clear
    // of the posedge the cores update on.
    always @(negedge clk_h) begin
        if (write_ref && nref < MAXQ) begin qref[nref] = out_ref; nref = nref + 1; end
        if (write_mux && nmux < MAXQ) begin qmux[nmux] = out_mux; nmux = nmux + 1; end
    end

    initial begin
        if (!$value$plusargs("pinv=%d",   pinv))   pinv   = 0;
        if (!$value$plusargs("pstuck=%d", pstuck)) pstuck = 0;
        in = 640'h0; read = 0;
        repeat (4) @(posedge clk_h);

        for (i = 0; i < N; i = i + 1) begin
            @(negedge clk_h);
            in = {$random,$random,$random,$random,$random,
                  $random,$random,$random,$random,$random,
                  $random,$random,$random,$random,$random,
                  $random,$random,$random,$random,$random};
            read = (i % 4 == 0);
            @(posedge clk_h);
            if (i % 50 == 0) begin
                $display("  progress: cycle %0d/%0d, results ref=%0d mux=%0d",
                         i, N, nref, nmux);
                $fflush();
            end
        end

        // Compare over the overlap; a deeper pipeline simply emits fewer
        // results in a fixed window.
        ncmp = (nref < nmux) ? nref : nmux;
        for (k = 0; k < ncmp; k = k + 1) begin
            if (qref[k] !== qmux[k]) begin
                nbad = nbad + 1;
                if (nbad <= 3)
                    $display("  RESULT MISMATCH #%0d:\n    ref=%h\n    mux=%h",
                             k, qref[k], qmux[k]);
            end
        end

        $display("");
        $display("=== encrypt core: stock vs pipelined shared-BRAM (sequence compare) ===");
        if (pstuck)      $display("  mode                : phase HELD CONSTANT (control -- must FAIL)");
        else if (pinv)   $display("  mode                : phase inverted");
        else             $display("  mode                : intended interleave");
        $display("  clk_h cycles driven : %0d", N);
        $display("  results emitted     : ref=%0d  mux=%0d", nref, nmux);
        $display("  results compared    : %0d", ncmp);
        $display("  mismatches          : %0d", nbad);
        if (ncmp < MIN_SEQ)
            $display("  RESULT: INCONCLUSIVE -- only %0d results (need %0d); run more cycles",
                     ncmp, MIN_SEQ);
        else if (nbad == 0)
            $display("  RESULT: PASS -- identical result sequences over %0d results", ncmp);
        else
            $display("  RESULT: FAIL");
        $finish;
    end
endmodule
