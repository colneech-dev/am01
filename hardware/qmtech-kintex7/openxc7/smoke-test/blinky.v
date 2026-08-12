module blinky(input clk, input rst, output [3:0] led);
    reg [27:0] ctr;
    always @(posedge clk) begin
        if (rst) ctr <= 28'd0;
        else     ctr <= ctr + 28'd1;
    end
    assign led = ctr[27:24];
endmodule
