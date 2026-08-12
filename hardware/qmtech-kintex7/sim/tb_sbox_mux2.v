`timescale 1ns/1ps
//
// Does one time-multiplexed BRAM give bit-exact results for TWO S-boxes?
//
// Drives sbox_large_mux2 (one shared BRAM on a 2x clock) and two plain
// reference S-boxes (one BRAM each, the current design) with the same
// random addresses, and checks every output on every clk_h edge.
//
// Passing means the 2x-multiplexed version is a drop-in replacement:
// same values, same 1-clk_h latency. That is what makes 4 instances fit
// where 2 fit today.
//
module tb;
    localparam AW = 10, DW = 10;
    localparam N  = 4000;         // random vectors

    reg clk2x = 0; always #2.5 clk2x = ~clk2x;   // 200 MHz-ish, 2x
    reg rst_n = 0;

    // clk_h is clk2x/2 -- generated from the same edge so they are
    // phase-aligned exactly as an MMCM would produce them.
    reg clk_h = 0;
    always @(posedge clk2x) clk_h <= ~clk_h;

    wire phase;
    sbox_mux_phase_gen phgen(.clk2x(clk2x), .rst_n(rst_n), .phase(phase));

    reg [AW-1:0] s0_a, s0_b, s1_a, s1_b;

    // ---- device under test: ONE BRAM serving both S-boxes ----
    wire [DW-1:0] m_s0_a, m_s0_b, m_s1_a, m_s1_b;
    sbox_large_mux2 #(.AW(AW), .DW(DW)) dut (
        .clk2x(clk2x), .phase(phase),
        .s0_a_in(s0_a), .s0_b_in(s0_b), .s0_a_out(m_s0_a), .s0_b_out(m_s0_b),
        .s1_a_in(s1_a), .s1_b_in(s1_b), .s1_a_out(m_s1_a), .s1_b_out(m_s1_b)
    );

    // ---- reference: two independent S-boxes, one BRAM each ----
    reg [DW-1:0] ref0 [0:(1<<AW)-1];
    reg [DW-1:0] ref1 [0:(1<<AW)-1];
    reg [DW-1:0] r_s0_a, r_s0_b, r_s1_a, r_s1_b;
    always @(posedge clk_h) begin
        r_s0_a <= ref0[s0_a];  r_s0_b <= ref0[s0_b];
        r_s1_a <= ref1[s1_a];  r_s1_b <= ref1[s1_b];
    end

    integer i, errs = 0, checks = 0;
    initial begin
        // Both slots share one table here (that is the point -- two users
        // of the same OdoCrypt table pair into one BRAM).
        for (i = 0; i < (1<<AW); i = i + 1) begin
            dut.mem[i] = $random;
            ref0[i]    = dut.mem[i];
            ref1[i]    = dut.mem[i];
        end
        s0_a=0; s0_b=0; s1_a=0; s1_b=0;
        repeat (4) @(posedge clk2x);
        rst_n = 1;
        repeat (4) @(posedge clk_h);

        for (i = 0; i < N; i = i + 1) begin
            @(negedge clk_h);
            s0_a = $random; s0_b = $random;
            s1_a = $random; s1_b = $random;
            @(posedge clk_h);          // address captured
            @(posedge clk_h);          // results settled (1 clk_h latency)
            checks = checks + 4;
            if (m_s0_a !== r_s0_a) begin errs=errs+1;
                $display("  MISMATCH v%0d s0_a: mux=%h ref=%h", i, m_s0_a, r_s0_a); end
            if (m_s0_b !== r_s0_b) begin errs=errs+1;
                $display("  MISMATCH v%0d s0_b: mux=%h ref=%h", i, m_s0_b, r_s0_b); end
            if (m_s1_a !== r_s1_a) begin errs=errs+1;
                $display("  MISMATCH v%0d s1_a: mux=%h ref=%h", i, m_s1_a, r_s1_a); end
            if (m_s1_b !== r_s1_b) begin errs=errs+1;
                $display("  MISMATCH v%0d s1_b: mux=%h ref=%h", i, m_s1_b, r_s1_b); end
            if (errs > 12) begin $display("  (too many mismatches, stopping)"); i = N; end
        end

        $display("");
        $display("=== 2x time-multiplexed S-box vs two independent S-boxes ===");
        $display("  vectors        : %0d", N);
        $display("  outputs checked: %0d", checks);
        $display("  mismatches     : %0d", errs);
        // NB: keep this as if/else, not a ternary between string literals --
        // Verilog treats those as numeric vectors of differing width.
        if (errs == 0)
            $display("  RESULT: PASS -- one BRAM serves two S-boxes, bit-exact, 1 clk_h latency");
        else
            $display("  RESULT: FAIL");
        $finish;
    end
endmodule
