`timescale 1ns / 1ps
// Elaboration-only harness: instantiate the wrapper with PANEL_IF="cyd" so the
// CYD branch of every generate is actually built. A parameter that only
// elaborates at its default is a parameter that does not work.
module tb_cydcfg;
    reg bus_clk=0, bus_rst_n=0, clk_h=0;
    wire [15:0] gpio_data;
    wire gpio_ready, gpio_irq, fan_pwm;
    wire lcd_sclk, lcd_mosi, lcd_cs_n, lcd_dc, lcd_rst_n, lcd_bl, touch_cs_n;
    odocrypt_gpio_wrapper #(.PANEL_IF("cyd")) dut (
        .bus_clk(bus_clk), .bus_rst_n(bus_rst_n), .gpio_data(gpio_data),
        .gpio_addr(5'h0), .gpio_wr_n(1'b1), .gpio_rd_n(1'b1),
        .gpio_ready(gpio_ready), .gpio_irq(gpio_irq), .clk_h(clk_h),
        .fan_pwm(fan_pwm), .fan_tach_in(1'b0),
        .lcd_sclk(lcd_sclk), .lcd_mosi(lcd_mosi), .lcd_miso(1'b1),
        .lcd_cs_n(lcd_cs_n), .lcd_dc(lcd_dc), .lcd_rst_n(lcd_rst_n),
        .lcd_bl(lcd_bl), .touch_cs_n(touch_cs_n), .touch_irq(1'b1));
    initial begin $display("PANEL_IF=cyd elaborated"); $finish; end
endmodule
