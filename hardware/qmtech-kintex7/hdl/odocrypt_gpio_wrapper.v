//////////////////////////////////////////////////////////////////////////////////
/*
 *  AtomMiner AM01 -- QMTECH Kintex-7 + Raspberry Pi CM4 variant, design proposal
 *
 *  Copyright 2015-2022 AtomMiner <atom@atomminer.com>
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation; either version 3 of the License, or (at your option)
 * any later version. If not, see <http://www.gnu.org/licenses/>.
 *
 */
//////////////////////////////////////////////////////////////////////////////////
//
// odocrypt_gpio_wrapper
//
// Replacement for exmaples/odocrypt/fpga/src/hdl/usb3_interface.v +
// usb3_sm_v3.v on the QMTECH XC7K325T + Raspberry Pi CM4 variant (see
// ../README.md). A Raspberry Pi CM4 plugged into the QMTECH board's CM4
// socket drives header/target words and reads the golden nonce over 24
// general-purpose GPIO lines using a simple 4-phase parallel bus, instead
// of the FX3's DQ-bus/USB link or the Zynq variant's on-chip AXI4-Lite.
// odo_block_data, host_break_sm and miner_top (and everything below
// them) are reused completely unmodified from hdl/odocrypt/ (a copy of
// exmaples/odocrypt/fpga/src/hdl/ kept in sync with the current OdoCrypt
// epoch -- see hdl/odocrypt/NOTICE).
//
// STATUS: reference skeleton for a hardware proposal, not verified/timed
// silicon-ready RTL. See "What's still needed before this is real
// hardware" in ../README.md -- in particular gpio_wr_n/gpio_rd_n/
// gpio_addr/gpio_data are asynchronous inputs from the CM4 (no shared
// clock), synchronized here with plain multi-flop synchronizers that
// still need ASYNC_REG + timing-exception signoff before tape-out.
//
// Register map (see ../README.md): 16-bit-per-beat, ADDR-selected.
//
`timescale 1ns / 1ps

module odocrypt_gpio_wrapper #(
    // Number of parallel hash-core instances. BRAM-bound on this chip:
    // one instance = 420 RAMB18 of the XC7K325T's 890 (measured), so 2
    // fills the budget at 94% and 3 does not fit. Set to 1 to get the
    // original single-core behaviour back. See ../README.md
    // "Expected hashrate" for the derivation.
    parameter integer NUM_MINERS = 2,

    // OdoCrypt epoch seed that hdl/odocrypt/encrypt.v was generated for,
    // read back by the host at SEED_LO/SEED_HI as bitstream_epoch.
    //
    // The default is the real value rather than 0 so it is correct without
    // either build flow having to pass a generic. It MUST match the seed
    // stamped in encrypt.v's header -- tools/check-epoch.sh enforces that and
    // flags staleness against the current date. Update both together.
    parameter [31:0] ODO_SEED = 32'd1787616000
) (
    // ---------------------------------------------------------------
    // Bus clock domain -- the board's onboard 50MHz crystal
    // (sys_clk_50m in the .xdc), or an MMCM-derived clock from it.
    // ---------------------------------------------------------------
    input  wire        bus_clk,
    input  wire        bus_rst_n,

    // ---------------------------------------------------------------
    // GPIO parallel bus to the CM4 socket. Asynchronous to bus_clk --
    // driven either by bit-banged GPIO or the BCM2711 SMI peripheral.
    // ---------------------------------------------------------------
    inout  wire [15:0] gpio_data,
    // 5 bits. GPIO16-19 were the original four; GPIO24 (FPGA ball B14) is
    // added as addr[4]. It was already routed to the FPGA -- the manual's
    // section 2.2.9 table wires GPIO0-27 to fabric -- but unused by this
    // design, so widening cost a constraint rather than a wire. 4 bits gave
    // 16 slots and all 16 were allocated once the XADC and fan registers
    // landed, leaving nowhere for the display.
    input  wire [4:0]  gpio_addr,
    input  wire        gpio_wr_n,   // active low
    input  wire        gpio_rd_n,   // active low
    output reg          gpio_ready,
    output wire        gpio_irq,    // level, asserted while a nonce is pending

    // ---------------------------------------------------------------
    // Hash-core clock domain. clk_h is whatever feeds miner_top today
    // (an MMCM output derived from the 50MHz crystal, same role
    // artix200_v3_clocking plays on the stock AM01).
    // ---------------------------------------------------------------
    input  wire        clk_h,

    // ---------------------------------------------------------------
    // Fan, on spare BANK12 I/O at JP5. PWM out, tach in. Driven from
    // fabric so cooling works with no software running.
    // ---------------------------------------------------------------
    output wire        fan_pwm,
    input  wire        fan_tach_in,

    // ---------------------------------------------------------------
    // ILI9341 panel + XPT2046 touch on JP5, sharing one SPI bus.
    // ---------------------------------------------------------------
    output wire        lcd_sclk,
    output wire        lcd_mosi,
    input  wire        lcd_miso,
    output wire        lcd_cs_n,
    output wire        lcd_dc,
    output wire        lcd_rst_n,
    output wire        lcd_bl,
    output wire        touch_cs_n,
    input  wire        touch_irq
);

    // -----------------------------------------------------------------
    // Register map
    // -----------------------------------------------------------------
    localparam [4:0] ADDR_VERSION     = 5'h0;
    localparam [4:0] ADDR_CTRL        = 5'h1;
    localparam [4:0] ADDR_STATUS      = 5'h2;
    localparam [4:0] ADDR_NONCE_LO    = 5'h3;
    localparam [4:0] ADDR_NONCE_HI    = 5'h4;
    localparam [4:0] ADDR_HEADER_LO   = 5'h5;
    localparam [4:0] ADDR_HEADER_HI   = 5'h6;
    localparam [4:0] ADDR_TARGET_LO   = 5'h7;
    localparam [4:0] ADDR_TARGET_HI   = 5'h8;
    // Read-only: the OdoCrypt epoch seed encrypt.v was generated for. The
    // daemon reads this back as bitstream_epoch and compares it against the
    // pool's job epoch; without it a stale bitstream mines rejects silently.
    localparam [4:0] ADDR_SEED_LO     = 5'h9;
    localparam [4:0] ADDR_SEED_HI     = 5'hA;
    // Raw XADC on-die temperature code, 16 bits as read from DRP 0x00 (only
    // the top 12 bits are significant). Converted host-side rather than here:
    //     degC = (code >> 4) * 503.975 / 4096 - 273.15
    // A raw value keeps the RTL to a latch and avoids fixed-point in fabric.
    // Reads 0 until the first conversion completes, a few us after reset.
    localparam [4:0] ADDR_TEMP        = 5'hB;
    // Supply rails, same XADC, same DRP, different channels. Default mode
    // already samples these alongside temperature, so they cost one more
    // latch each. VCCINT matters most: this design draws ~12A at 1.0V through
    // the MP8712, and a sagging core rail produces wrong hash results while
    // everything still looks healthy -- silent rejects, not a crash.
    //     volts = (code >> 4) * 3.0 / 4096
    localparam [4:0] ADDR_VCCINT      = 5'hC;
    localparam [4:0] ADDR_VCCAUX      = 5'hD;
    localparam [4:0] ADDR_VCCBRAM     = 5'hE;
    // Fan. Read : [7:0] current duty (0-255), [15:8] tach pulses/sec.
    //      Write: [7:0] minimum duty floor; 0 = fully automatic.
    // Control is closed-loop in fabric off the XADC die temperature, so the
    // fan is correct from power-on -- before Linux boots, and regardless of
    // whether the Pi or the miner is alive. This design free-runs at full
    // power the moment it configures from flash, so cooling must not depend
    // on software having started.
    localparam [4:0] ADDR_FAN         = 5'hF;

    // ---- ILI9341 display, in the space the 5th address bit opened up ----
    // The panel has its own GRAM, so the FPGA never holds a framebuffer --
    // it is a transport: the host writes command/data bytes and they go out
    // over SPI. That is why this needs no BRAM, which matters at 94% RAMB18.
    //
    // LCD_DATA is deliberately its own slot: pixel writes are the only
    // high-traffic path here, and keeping them on a fixed address means the
    // host can hammer one register without re-addressing.
    localparam [4:0] ADDR_LCD_CMD     = 5'h10;  // write: command byte, DC=0
    localparam [4:0] ADDR_LCD_DATA    = 5'h11;  // write: data/pixel, DC=1
    localparam [4:0] ADDR_LCD_STAT    = 5'h12;  // read: busy/fifo state
    localparam [4:0] ADDR_LCD_CTRL    = 5'h13;  // write: [0] RST_N [1] backlight
    localparam [4:0] ADDR_TOUCH_X     = 5'h14;  // read: XPT2046 X
    localparam [4:0] ADDR_TOUCH_Y     = 5'h15;  // read: XPT2046 Y
    localparam [4:0] ADDR_TOUCH_STAT  = 5'h16;  // read: [0] pressed

    // v1.1 adds SEED_LO/SEED_HI. The daemon treats a VERSION below this as
    // "seed unreadable" rather than misreading 0 as a real epoch.
    // v1.2 adds TEMP, the XADC supply rails, and autonomous fan control.
    // v1.3 widens gpio_addr to 5 bits and adds the ILI9341/XPT2046 block.
    // A v1.2-or-older host driving only 4 address lines still works: the
    // fifth line idles low, so it addresses 0x00-0x0F exactly as before.
    localparam [15:0] VERSION = 16'h0103;

    // Request opcodes carried across the bus_clk -> clk_h handshake.
    localparam [1:0] OP_HEADER_WORD = 2'b00;
    localparam [1:0] OP_TARGET_WORD = 2'b01;
    localparam [1:0] OP_HOST_BREAK  = 2'b10;
    localparam [1:0] OP_SOFT_RESET  = 2'b11;

    // =====================================================================
    // Synchronize the async CM4-driven bus into bus_clk. ADDR/DATA are
    // sampled only once WR_N/RD_N has been seen low for two consecutive
    // bus_clk cycles, so they're required to be stable before the strobe
    // asserts -- standard practice for a source-synchronous-ish bus with
    // no shared clock.
    // =====================================================================
    // ASYNC_REG on the first flop of each chain: tells P&R to place it
    // close to whatever feeds it and prioritize it for MTBF, since it's
    // the one actually catching an asynchronous input mid-transition.
    // Paired with the set_clock_groups -asynchronous in the .xdc between
    // sys_clk_50m and clk_h -- that tells STA these two clocks aren't
    // meant to be timed against each other; this tells P&R the flops
    // that assumption depends on need real metastability handling.
    // wr_sync/rd_sync are stored ACTIVE-HIGH (inverted from the raw
    // active-low gpio_wr_n/gpio_rd_n) purely so their idle/reset state is
    // all-zero instead of all-one. That is not cosmetic: a reset-to-1
    // register synthesizes to FDSE ("set" primitive) instead of FDRE
    // ("reset" primitive), and FDRE/FDSE turn out to be JUST as
    // half-slice-incompatible as the sync/async split above -- confirmed
    // by hitting a second real 'control-set contention' FASM error, on
    // this exact register, after already eliminating FDCE/FDPE. Same
    // fix category, one bit of polarity instead of a sensitivity list.
    // Functionally identical either way -- see wr_active/rd_active and
    // the S_WRITE/S_READ release checks below, which un-invert as needed.
    (* ASYNC_REG = "TRUE" *) reg [2:0] wr_sync, rd_sync;
    (* ASYNC_REG = "TRUE" *) reg [4:0] addr_sync0;
    reg [4:0]  addr_sync1;
    (* ASYNC_REG = "TRUE" *) reg [15:0] data_in_sync0;
    reg [15:0] data_in_sync1;

    // Synchronous reset deliberately, not async: bus_rst_n is already
    // deasserted synchronously (see am01_qmtech_top.v's rst_stretch
    // counter), so nothing here needs true async behaviour. Kept sync
    // for a real, measured reason -- see openxc7/README.md "Why every
    // reset in this file is synchronous": Xilinx 7-series async-set/
    // reset FFs (FDCE/FDPE) route through the same half-slice control
    // network as the sync ones (FDRE/FDSE), and nextpnr-xilinx's placer
    // does not reliably keep the two families apart -- confirmed via a
    // real 'control-set contention' FASM error on 2/2 random seeds
    // before this fix. Vivado handles the mix fine; this is an openXC7
    // portability fix, not a correctness bug this file ever had.
    always @(posedge bus_clk) begin
        if (!bus_rst_n) begin
            wr_sync <= 3'b000;
            rd_sync <= 3'b000;
        end else begin
            wr_sync <= {wr_sync[1:0], ~gpio_wr_n};
            rd_sync <= {rd_sync[1:0], ~gpio_rd_n};
        end
    end

    always @(posedge bus_clk) begin
        addr_sync0 <= gpio_addr;
        addr_sync1 <= addr_sync0;
        data_in_sync0 <= gpio_data;
        data_in_sync1 <= data_in_sync0;
    end

    wire wr_active = wr_sync[2] & wr_sync[1]; // debounced write request
    wire rd_active = rd_sync[2] & rd_sync[1]; // debounced read request

    // =====================================================================
    // bus_clk -> clk_h request/ack handshake (same two-phase toggle
    // synchronizer pattern as hardware/zynq/hdl/odocrypt_axi_wrapper.v).
    // req_toggle_bus only flips once the previous request has been
    // ack'd, enforced below by holding the bus state machine (and thus
    // GPIO_READY) until ack_pulse_bus arrives, so req_op/req_data are
    // guaranteed stable for the whole round trip.
    // =====================================================================
    reg        req_toggle_bus;
    reg [1:0]  req_op_bus;
    reg [31:0] req_data_bus;

    (* ASYNC_REG = "TRUE" *) reg req_sync1_h;
    reg req_sync2_h, req_sync3_h;
    reg ack_toggle_h;
    (* ASYNC_REG = "TRUE" *) reg ack_sync1_bus;
    reg ack_sync2_bus, ack_sync3_bus;

    wire req_pulse_h   = req_sync2_h ^ req_sync3_h;
    wire ack_pulse_bus = ack_sync2_bus ^ ack_sync3_bus;

    always @(posedge clk_h) begin
        req_sync1_h <= req_toggle_bus;
        req_sync2_h <= req_sync1_h;
        req_sync3_h <= req_sync2_h;
        if (req_pulse_h)
            ack_toggle_h <= ~ack_toggle_h;
    end

    always @(posedge bus_clk) begin
        ack_sync1_bus <= ack_toggle_h;
        ack_sync2_bus <= ack_sync1_bus;
        ack_sync3_bus <= ack_sync2_bus;
    end

    // =====================================================================
    // XADC on-die temperature.
    //
    // The Kintex-7 has a built-in temperature sensor; this is the die
    // temperature, not a heatsink probe, which is what actually matters for
    // a design that free-runs at full power the moment it configures. There
    // is nowhere on this board to attach an external sensor anyway: all 28
    // CM4 GPIOs go to FPGA fabric pins and JP5 is FPGA I/O, so the daemon's
    // DS18B20 support (inherited from the Cyclone V variant) cannot be used.
    //
    // Default mode (CFG1[15:12]=0000) free-runs a sequence including the
    // temperature channel with no sequencer setup, so this only has to poll
    // DRP address 0x00 and latch the result. ADCCLK = DCLK/8 = 6.25MHz from
    // the 50MHz bus_clk, inside the 1-26MHz the ADC requires.
    //
    // VP/VN are tied off: the internal sensor does not use the external
    // analog inputs, and the schematic grounds DXP_0/DXN_0.
    // =====================================================================
    wire [15:0] xadc_do;
    wire        xadc_drdy;
    reg         xadc_den;
    reg  [6:0]  xadc_daddr;
    reg  [1:0]  xadc_chan;      // which of the four we are currently reading
    reg  [15:0] xadc_temp_bus;
    reg  [15:0] xadc_vccint_bus;
    reg  [15:0] xadc_vccaux_bus;
    reg  [15:0] xadc_vccbram_bus;
    reg  [7:0]  xadc_wait;

    // DRP addresses, in the order xadc_chan cycles through them.
    function [6:0] chan_addr(input [1:0] c);
        case (c)
            2'd0: chan_addr = 7'h00;  // temperature
            2'd1: chan_addr = 7'h01;  // VCCINT
            2'd2: chan_addr = 7'h02;  // VCCAUX
            default: chan_addr = 7'h06;  // VCCBRAM
        endcase
    endfunction

    always @(posedge bus_clk or negedge bus_rst_n) begin
        if (!bus_rst_n) begin
            xadc_den         <= 1'b0;
            xadc_daddr       <= 7'h00;
            xadc_chan        <= 2'd0;
            xadc_temp_bus    <= 16'h0000;
            xadc_vccint_bus  <= 16'h0000;
            xadc_vccaux_bus  <= 16'h0000;
            xadc_vccbram_bus <= 16'h0000;
            xadc_wait        <= 8'd0;
        end else begin
            xadc_den <= 1'b0;                 // single-cycle strobe

            if (xadc_drdy) begin
                case (xadc_chan)
                    2'd0: xadc_temp_bus    <= xadc_do;
                    2'd1: xadc_vccint_bus  <= xadc_do;
                    2'd2: xadc_vccaux_bus  <= xadc_do;
                    2'd3: xadc_vccbram_bus <= xadc_do;
                endcase
                xadc_chan <= xadc_chan + 2'd1;   // wraps at 4
            end

            // One channel roughly every 256 bus_clk cycles (~5us), so all
            // four refresh in ~20us -- far faster than either the sensor
            // changes or the host polls, and light enough on the DRP port.
            if (xadc_wait == 8'd0) begin
                xadc_daddr <= chan_addr(xadc_chan);
                xadc_den   <= 1'b1;
                xadc_wait  <= 8'hFF;
            end else begin
                xadc_wait <= xadc_wait - 8'd1;
            end
        end
    end

    // NO_XADC builds the design without the on-die monitor.
    //
    // Not a preference -- the open-source flow CANNOT place an XADC on this
    // part. prjxray's kintex7 database contains zero XADC/MONITOR tiles, so
    // nextpnr-xilinx has no bel to bind to and place-and-route dies with
    //   ERROR: Unable to place cell '...xadc_inst', no Bels remaining of
    //          type 'XADC'
    // nextpnr's only mentions of XADC are an invertible-pin entry and an
    // error message; there is no packer support. Closing that gap means
    // fuzzing the XADC configuration into prjxray, which is real work.
    //
    // Leaving the reads tied to zero is already a defined state rather than a
    // hack: the fan controller below treats a raw code of 0 as "the XADC has
    // not produced a reading" and falls back to full-speed cooling, which is
    // exactly the correct behaviour for a bitstream that has no monitor.
    // Vivado builds are unaffected -- do not pass the define there.
`ifdef NO_XADC
    assign xadc_do   = 16'h0000;
    assign xadc_drdy = 1'b0;
`else
    XADC #(
        .INIT_40(16'h0000),   // CFG0: no averaging, unipolar, temperature
        .INIT_41(16'h0F0F),   // CFG1: default mode, all alarms disabled
        .INIT_42(16'h0800),   // CFG2: DCLK divider = 8 -> ADCCLK 6.25MHz
        .SIM_MONITOR_FILE("design.txt")
    ) xadc_inst (
        .DADDR  (xadc_daddr),
        .DCLK   (bus_clk),
        .DEN    (xadc_den),
        .DI     (16'h0000),
        .DWE    (1'b0),
        .DO     (xadc_do),
        .DRDY   (xadc_drdy),
        .RESET  (~bus_rst_n),
        .VP     (1'b0),
        .VN     (1'b0),
        .VAUXP  (16'h0000),
        .VAUXN  (16'h0000),
        .CONVST (1'b0),
        .CONVSTCLK (1'b0),
        .JTAGBUSY  (),
        .JTAGLOCKED(),
        .JTAGMODIFIED(),
        .OT     (),
        .ALM    (),
        .MUXADDR(),
        .CHANNEL(),
        .EOC    (),
        .EOS    (),
        .BUSY   ()
    );
`endif

    // =====================================================================
    // ILI9341 display + XPT2046 touch, sharing one SPI bus.
    //
    // The FPGA is a transport here, not a graphics engine: the panel has its
    // own GRAM, so nothing is stored on this side. The host writes a command
    // byte to LCD_CMD (DC low) or a 16-bit pixel to LCD_DATA (DC high) and
    // this shifts it out. No framebuffer means no BRAM, which is the only
    // reason it fits in a design already at 94% RAMB18.
    //
    // SCLK is bus_clk/8 = 6.25MHz. Conservative on purpose -- none of this
    // has been near real silicon, and a slow bus is far easier to debug than
    // a marginal one.
    // =====================================================================
    reg  [15:0] spi_shift;
    reg  [4:0]  spi_bits;
    reg  [2:0]  spi_div;
    reg         spi_busy;
    reg         spi_dc;
    reg         spi_cs_lcd_n;
    reg         spi_sclk;
    reg         spi_mosi;
    reg         lcd_rst_n_r;
    reg         lcd_bl_r;
    reg  [11:0] touch_x, touch_y;
    reg         touch_pressed;

    // Driven by the bus FSM on a write to LCD_CMD / LCD_DATA / LCD_CTRL.
    reg         lcd_start;
    reg  [15:0] lcd_start_data;
    reg         lcd_start_dc;
    reg         lcd_start_16;
    reg         lcd_ctrl_wr;
    reg  [15:0] lcd_ctrl_data;

    assign lcd_sclk   = spi_sclk;
    assign lcd_mosi   = spi_mosi;
    assign lcd_cs_n   = spi_cs_lcd_n;
    assign lcd_dc     = spi_dc;
    assign lcd_rst_n  = lcd_rst_n_r;
    assign lcd_bl     = lcd_bl_r;
    assign touch_cs_n = 1'b1;   // touch controller idle for now

    always @(posedge bus_clk or negedge bus_rst_n) begin
        if (!bus_rst_n) begin
            spi_shift     <= 16'h0;
            spi_bits      <= 5'd0;
            spi_div       <= 3'd0;
            spi_busy      <= 1'b0;
            spi_dc        <= 1'b0;
            spi_cs_lcd_n  <= 1'b1;
            spi_sclk      <= 1'b0;
            spi_mosi      <= 1'b0;
            lcd_rst_n_r   <= 1'b0;   // hold the panel in reset
            lcd_bl_r      <= 1'b0;   // backlight off until configured
            touch_x       <= 12'h0;
            touch_y       <= 12'h0;
            touch_pressed <= 1'b0;
        end else begin
            if (lcd_start && !spi_busy) begin
                spi_shift    <= lcd_start_16 ? lcd_start_data
                                             : {lcd_start_data[7:0], 8'h00};
                spi_bits     <= lcd_start_16 ? 5'd16 : 5'd8;
                spi_dc       <= lcd_start_dc;
                spi_cs_lcd_n <= 1'b0;
                spi_busy     <= 1'b1;
                spi_div      <= 3'd0;
                spi_sclk     <= 1'b0;
            end else if (spi_busy) begin
                spi_div <= spi_div + 3'd1;
                if (spi_div == 3'd3) begin
                    spi_div <= 3'd0;
                    if (!spi_sclk) begin
                        // SPI mode 0: shift on the falling edge, the panel
                        // samples on the rising one.
                        spi_mosi  <= spi_shift[15];
                        spi_shift <= {spi_shift[14:0], 1'b0};
                        spi_sclk  <= 1'b1;
                    end else begin
                        spi_sclk <= 1'b0;
                        spi_bits <= spi_bits - 5'd1;
                        if (spi_bits == 5'd1) begin
                            spi_busy     <= 1'b0;
                            spi_cs_lcd_n <= 1'b1;
                        end
                    end
                end
            end

            if (lcd_ctrl_wr) begin
                lcd_rst_n_r <= lcd_ctrl_data[0];
                lcd_bl_r    <= lcd_ctrl_data[1];
            end

            // XPT2046 PENIRQ is active low, open drain.
            touch_pressed <= ~touch_irq;
        end
    end

    // =====================================================================
    // Fan control -- closed loop on die temperature, entirely in fabric.
    //
    // Thresholds are compared against the RAW XADC code to keep this to
    // magnitude comparators; no conversion arithmetic in fabric.
    //     code = (degC + 273.15) * 4096 / 503.975, then << 4
    //       40C -> 16'h9F10   55C -> 16'hA6E0
    //       70C -> 16'hAEB0   85C -> 16'hB680
    //
    // FAIL-SAFE: a raw code of 0 means the XADC has not produced a reading
    // yet (or is not working). That runs the fan at 100%, not 0% -- an
    // unknown temperature must never be treated as a cold one.
    // =====================================================================
    localparam [15:0] TEMP_40C = 16'h9F10;
    localparam [15:0] TEMP_55C = 16'hA6E0;
    localparam [15:0] TEMP_70C = 16'hAEB0;
    localparam [15:0] TEMP_85C = 16'hB680;

    reg  [7:0]  fan_duty;        // 0-255, what we are actually driving
    reg  [7:0]  fan_floor;       // host-settable minimum, 0 = pure auto
    reg  [10:0] fan_pwm_cnt;
    reg  [7:0]  fan_tach_hz;     // tach pulses in the last second
    reg  [7:0]  fan_tach_acc;
    reg  [25:0] fan_sec_cnt;
    reg  [2:0]  tach_sync;

    wire [7:0] fan_auto =
          (xadc_temp_bus == 16'h0000) ? 8'd255 :   // unknown -> full
          (xadc_temp_bus >= TEMP_85C) ? 8'd255 :
          (xadc_temp_bus >= TEMP_70C) ? 8'd191 :
          (xadc_temp_bus >= TEMP_55C) ? 8'd140 :
          (xadc_temp_bus >= TEMP_40C) ? 8'd102 :
                                        8'd77;    // ~30% floor, never off

    always @(posedge bus_clk or negedge bus_rst_n) begin
        if (!bus_rst_n) begin
            fan_duty     <= 8'd255;   // full until we know better
            // fan_floor is NOT reset here. It is written by the bus state
            // machine (ADDR_FAN), and a register driven from two always blocks
            // is a multiple-driver conflict -- yosys reported exactly that on
            // all 8 bits. This block only READS it, which is fine; ownership
            // sits with the block that writes it, and the reset went with it.
            fan_pwm_cnt  <= 11'd0;
            fan_sec_cnt  <= 26'd0;
            fan_tach_acc <= 8'd0;
            fan_tach_hz  <= 8'd0;
            tach_sync    <= 3'b000;
        end else begin
            fan_duty    <= (fan_auto > fan_floor) ? fan_auto : fan_floor;
            fan_pwm_cnt <= fan_pwm_cnt + 11'd1;   // free-running, wraps

            // Tach: count rising edges over one second of bus_clk.
            tach_sync <= {tach_sync[1:0], fan_tach_in};
            if (tach_sync[2:1] == 2'b01 && fan_tach_acc != 8'hFF)
                fan_tach_acc <= fan_tach_acc + 8'd1;

            if (fan_sec_cnt >= 26'd49_999_999) begin
                fan_sec_cnt  <= 26'd0;
                fan_tach_hz  <= fan_tach_acc;
                fan_tach_acc <= 8'd0;
            end else begin
                fan_sec_cnt <= fan_sec_cnt + 26'd1;
            end
        end
    end

    // 50MHz / 2048 = 24.4kHz, inside the 21-28kHz a 4-pin PWM fan expects.
    // duty<<3 spreads 0-255 across the 0-2047 counter without a divide.
    assign fan_pwm = (fan_pwm_cnt < {fan_duty, 3'b000});

    // =====================================================================
    // Bus-side state machine: 4-phase interlocked handshake, one
    // register access at a time.
    // =====================================================================
    localparam S_IDLE  = 2'd0,
               S_WRITE = 2'd1,
               S_READ  = 2'd2;

    reg [1:0]  bus_state;
    reg [4:0]  addr_latched;
    reg [15:0] wdata_latched;
    reg [15:0] header_lo_stage, target_lo_stage;
    reg        request_issued;
    reg [15:0] rdata_reg;
    reg        gpio_data_oe;

    // Status/nonce values, already synchronized into bus_clk further down.
    wire        hash_active_bus;
    wire        nonce_valid_bus;
    wire [31:0] golden_nonce_bus;
    reg         nonce_valid_clear_pulse;

    // Synchronous reset deliberately -- see the sync-vs-async note above
    // wr_sync/rd_sync's always block; same reasoning applies here.
    always @(posedge bus_clk) begin
        if (!bus_rst_n) begin
            bus_state       <= S_IDLE;
            gpio_ready      <= 1'b0;
            gpio_data_oe    <= 1'b0;
            request_issued  <= 1'b0;
            // NOTE: req_toggle_bus is deliberately NOT reset here.
            //
            // It is a toggle, not a state -- only its TRANSITIONS carry meaning,
            // and the clk_h receiver detects them as req_sync2_h ^ req_sync3_h.
            // Forcing it to 0 on reset creates an edge if it happened to be 1,
            // which fires one spurious request on the clk_h side carrying stale
            // req_op_bus/req_data_bus. Because odo_block_data is a plain 19-deep
            // shift register with no word counter and no position reset, a single
            // extra get_block_pulse_h shifts the entire header by one 32-bit word
            // -- after which the miner runs normally and every result is wrong,
            // with no recovery path (OP_SOFT_RESET clears the word counters but
            // not the shift-register position).
            //
            // The clk_h synchroniser has no reset of its own, so leaving this
            // undisturbed is what keeps the two sides consistent across a bus
            // reset. Do not "tidy" this into the reset list.
            header_lo_stage <= 16'h0;
            target_lo_stage <= 16'h0;
            nonce_valid_clear_pulse <= 1'b0;
            // Host-settable fan floor. Owned here because this block writes it
            // (S_WRITE/ADDR_FAN); the fan controller only reads it.
            //
            // 0 means "pure auto", which is the safe default: the automatic
            // curve never falls below ~30% duty, so a zeroed floor cannot stop
            // the fan. This reset is synchronous while the fan block's is
            // asynchronous, so fan_floor now clears one bus_clk later than it
            // used to. That is harmless -- fan_duty resets to 255 (full) and
            // the PWM period is 2048 cycles, so a single stale cycle cannot
            // show up as reduced cooling.
            fan_floor       <= 8'd0;
        end else begin
            nonce_valid_clear_pulse <= 1'b0;

            case (bus_state)
                S_IDLE: begin
                    gpio_ready   <= 1'b0;
                    gpio_data_oe <= 1'b0;
                    request_issued <= 1'b0;
                    // One-shot strobes into the SPI/display block.
                    lcd_start    <= 1'b0;
                    lcd_ctrl_wr  <= 1'b0;
                    if (wr_active) begin
                        addr_latched  <= addr_sync1;
                        wdata_latched <= data_in_sync1;
                        bus_state     <= S_WRITE;
                    end else if (rd_active) begin
                        addr_latched <= addr_sync1;
                        bus_state    <= S_READ;
                    end
                end

                S_WRITE: begin
                    case (addr_latched)
                        // Minimum fan duty. Purely a floor: the automatic
                        // curve still applies above it, so the host can raise
                        // cooling but never disable it.
                        ADDR_FAN: begin
                            fan_floor  <= wdata_latched[7:0];
                            gpio_ready <= 1'b1;
                        end
                        // Display writes are dropped if the shifter is still
                        // busy; the host polls LCD_STAT before writing.
                        ADDR_LCD_CMD: begin
                            if (!spi_busy) begin
                                lcd_start_data <= wdata_latched;
                                lcd_start_dc   <= 1'b0;
                                lcd_start_16   <= 1'b0;
                                lcd_start      <= 1'b1;
                            end
                            gpio_ready <= 1'b1;
                        end
                        ADDR_LCD_DATA: begin
                            if (!spi_busy) begin
                                lcd_start_data <= wdata_latched;
                                lcd_start_dc   <= 1'b1;
                                lcd_start_16   <= 1'b1;
                                lcd_start      <= 1'b1;
                            end
                            gpio_ready <= 1'b1;
                        end
                        ADDR_LCD_CTRL: begin
                            lcd_ctrl_data <= wdata_latched;
                            lcd_ctrl_wr   <= 1'b1;
                            gpio_ready    <= 1'b1;
                        end
                        ADDR_CTRL: begin
                            if (!request_issued) begin
                                req_op_bus     <= wdata_latched[1] ? OP_HOST_BREAK : OP_SOFT_RESET;
                                req_data_bus   <= {16'h0, wdata_latched};
                                req_toggle_bus <= ~req_toggle_bus;
                                request_issued <= 1'b1;
                            end else if (ack_pulse_bus) begin
                                gpio_ready <= 1'b1;
                            end
                        end
                        ADDR_HEADER_LO: begin
                            header_lo_stage <= wdata_latched;
                            gpio_ready      <= 1'b1; // staging only, no clk_h side effect
                        end
                        ADDR_HEADER_HI: begin
                            if (!request_issued) begin
                                req_op_bus     <= OP_HEADER_WORD;
                                req_data_bus   <= {wdata_latched, header_lo_stage};
                                req_toggle_bus <= ~req_toggle_bus;
                                request_issued <= 1'b1;
                            end else if (ack_pulse_bus) begin
                                gpio_ready <= 1'b1;
                            end
                        end
                        ADDR_TARGET_LO: begin
                            target_lo_stage <= wdata_latched;
                            gpio_ready      <= 1'b1; // staging only
                        end
                        ADDR_TARGET_HI: begin
                            if (!request_issued) begin
                                req_op_bus     <= OP_TARGET_WORD;
                                req_data_bus   <= {wdata_latched, target_lo_stage};
                                req_toggle_bus <= ~req_toggle_bus;
                                request_issued <= 1'b1;
                            end else if (ack_pulse_bus) begin
                                gpio_ready <= 1'b1;
                            end
                        end
                        default: begin
                            // Write to a read-only/unmapped address: ack, no effect.
                            gpio_ready <= 1'b1;
                        end
                    endcase

                    if (gpio_ready && !wr_sync[2]) begin
                        // CM4 released WR_N after seeing READY (wr_sync is
                        // active-high, so "released" is 0, not 1 -- see
                        // its declaration comment).
                        gpio_ready <= 1'b0;
                        bus_state  <= S_IDLE;
                    end
                end

                S_READ: begin
                    case (addr_latched)
                        ADDR_VERSION:  rdata_reg <= VERSION;
                        ADDR_STATUS:   rdata_reg <= {14'h0, nonce_valid_bus, hash_active_bus};
                        ADDR_NONCE_LO: rdata_reg <= golden_nonce_bus[15:0];
                        ADDR_NONCE_HI: begin
                            rdata_reg <= golden_nonce_bus[31:16];
                            nonce_valid_clear_pulse <= 1'b1; // clears NONCE_VALID / irq
                        end
                        ADDR_SEED_LO:  rdata_reg <= ODO_SEED[15:0];
                        ADDR_SEED_HI:  rdata_reg <= ODO_SEED[31:16];
                        ADDR_TEMP:     rdata_reg <= xadc_temp_bus;
                        ADDR_VCCINT:   rdata_reg <= xadc_vccint_bus;
                        ADDR_VCCAUX:   rdata_reg <= xadc_vccaux_bus;
                        ADDR_VCCBRAM:  rdata_reg <= xadc_vccbram_bus;
                        ADDR_FAN:      rdata_reg <= {fan_tach_hz, fan_duty};
                        ADDR_LCD_STAT: rdata_reg <= {15'h0, spi_busy};
                        ADDR_TOUCH_X:  rdata_reg <= {4'h0, touch_x};
                        ADDR_TOUCH_Y:  rdata_reg <= {4'h0, touch_y};
                        ADDR_TOUCH_STAT: rdata_reg <= {15'h0, touch_pressed};
                        default: rdata_reg <= 16'h0;
                    endcase
                    gpio_data_oe <= 1'b1;
                    gpio_ready   <= 1'b1;

                    if (gpio_ready && !rd_sync[2]) begin
                        // CM4 released RD_N after seeing READY (rd_sync is
                        // active-high -- see wr_sync's declaration comment).
                        gpio_ready   <= 1'b0;
                        gpio_data_oe <= 1'b0;
                        bus_state    <= S_IDLE;
                    end
                end

                default: bus_state <= S_IDLE;
            endcase
        end
    end

    assign gpio_data = gpio_data_oe ? rdata_reg : 16'bz;

    // =====================================================================
    // Hash-core (clk_h) domain: decode the request into the same pulses
    // odo_block_data / host_break_sm expect, and drive miner_top exactly
    // like exmaples/odocrypt/fpga/src/hdl/atomminer_odocrypt.v did. This
    // section mirrors hardware/zynq/hdl/odocrypt_axi_wrapper.v verbatim.
    // =====================================================================
    reg [31:0] data_from_host_h;
    reg        get_block_pulse_h;
    reg        get_target_pulse_h;
    reg        host_break_pulse_h;

    reg [4:0]  header_word_cnt_h; // 0..18, 19 words total
    reg [3:0]  target_word_cnt_h; // 0..7,  8 words total
    reg        start_hash_h;

    always @(posedge clk_h) begin
        get_block_pulse_h  <= 1'b0;
        get_target_pulse_h <= 1'b0;
        host_break_pulse_h <= 1'b0;

        if (req_pulse_h) begin
            data_from_host_h <= req_data_bus;
            case (req_op_bus)
                OP_HEADER_WORD: begin
                    get_block_pulse_h <= 1'b1;
                    header_word_cnt_h <= header_word_cnt_h + 1'b1;
                end
                OP_TARGET_WORD: begin
                    get_target_pulse_h <= 1'b1;
                    target_word_cnt_h  <= target_word_cnt_h + 1'b1;
                    if (target_word_cnt_h == 4'd7)
                        start_hash_h <= 1'b1; // 8th (last) target word arms the core
                end
                OP_HOST_BREAK: begin
                    host_break_pulse_h <= 1'b1;
                end
                OP_SOFT_RESET: begin
                    header_word_cnt_h <= 5'h0;
                    target_word_cnt_h <= 4'h0;
                    start_hash_h      <= 1'b0;
                end
            endcase
        end

        if (host_break_debounced)
            start_hash_h <= 1'b0;
    end

    wire [607:0] header;
    wire [255:0] target;
    wire         host_break_debounced; // = host_break_sm's sha_host_break output
    wire         ticket2moon;
    wire [31:0]  golden_nonce_h;

    odo_block_data odo_block_data_inst (
        .clk_h            (clk_h),
        .data_from_host_in(data_from_host_h),
        .get_midstate_in  (1'b0), // GPIO side collapses midstate/block into one FIFO
        .get_block_in     (get_block_pulse_h),
        .get_target_in    (get_target_pulse_h),
        .header           (header),
        .target           (target)
    );

    host_break_sm host_break_sm_inst (
        .clk_h         (clk_h),
        .host_break    (host_break_pulse_h),
        .ticket2moon   (ticket2moon_i),   // gated -- see below, NOT raw
        .hash_cmplt    (1'b0),
        .sha_host_break(host_break_debounced)
    );

    // -----------------------------------------------------------------
    // Hash-core bank. NUM_MINERS instances share one work item, each
    // sweeping its own slice of the 32-bit nonce space via NONCE_BASE.
    //
    // Why more than one: a single instance uses 420 RAMB18 of this
    // chip's 890 (measured -- they are OdoCrypt's large S-boxes), i.e.
    // it leaves nearly half the block RAM idle while using only ~9% of
    // the logic. Total hashrate here is BRAM-bound at roughly
    // 0.5 x Fmax, and one instance only reaches half of that. See
    // ../README.md "Expected hashrate".
    //
    // NUM_MINERS=2 fills the BRAM budget. MEASURED by walking the
    // synthesised hierarchy (not estimated): 1 instance = 420 RAMB18
    // (47.2% of the XC7K325T's 890), 2 instances = 840 (94.4%) -- fits,
    // with 50 RAMB18 spare. 3 would need 1260 and cannot fit. Do not
    // raise this without re-measuring.
    // -----------------------------------------------------------------
    wire [NUM_MINERS-1:0] t2m_arr;
    wire [31:0]           nonce_arr [0:NUM_MINERS-1];

    genvar gi;
    generate
        for (gi = 0; gi < NUM_MINERS; gi = gi + 1) begin : g_miner
            miner_top #(
                // Even split of the nonce space: instance gi sweeps
                // [gi*span, (gi+1)*span). For NUM_MINERS=2 that is
                // 0x00000000 and 0x80000000.
                .NONCE_BASE(gi * ((32'hFFFFFFFF / NUM_MINERS) + 32'h1))
            ) miner_top_inst (
                .osc_clk    (clk_h),
                .header     (header),
                .target     (target),
                .start_hash (start_hash_h),
                .ticket2moon(t2m_arr[gi]),
                .nonce      (nonce_arr[gi])
            );
        end
    endgenerate

    // Any instance finding a solution raises the shared ticket2moon.
    assign ticket2moon = |t2m_arr;

    // Pick the winning instance's nonce. If two hit on the same cycle
    // the lower index wins and the other is lost -- the same
    // single-latch limitation ../README.md already documents for
    // back-to-back solves, not a new one introduced by the bank.
    integer mi;
    reg [31:0] golden_nonce_mux;
    always @* begin
        golden_nonce_mux = nonce_arr[0];
        for (mi = NUM_MINERS - 1; mi >= 0; mi = mi - 1)
            if (t2m_arr[mi]) golden_nonce_mux = nonce_arr[mi];
    end
    assign golden_nonce_h = golden_nonce_mux;

    // -----------------------------------------------------------------
    // ticket2moon qualification -- must match atomminer_odocrypt.v.
    //
    // miner_top's `ticket2moon` is the RAW combinational "hash meets
    // target" comparator coming out of odo_keccak (miner.v ends with
    // `assign ticket2moon = res;`), and miner.v captures its own `nonce`
    // only under `has_res & start_hash & nonce_out_go`. The reference top
    // level never consumes that raw signal: it builds a gated, registered
    // copy and feeds *that* to both host_break_sm and its result path
    // (atomminer_odocrypt.v, lines ~158 / ~176 / ~221):
    //
    //     always @ (posedge clk_h)
    //         ticket2moon_i <= ticket2moon & nonce_out_go_top;
    //
    // An earlier revision of this wrapper used the raw signal in both
    // places while claiming in comments to mirror that file. This restores
    // the reference's behaviour.
    //
    // HONESTY NOTE ON WHY: this is reference fidelity / defence in depth,
    // NOT a demonstrated bug fix. Two failure modes were hypothesised for
    // the raw signal -- a spurious assertion during pipeline warm-up, and
    // a multi-cycle level breaking the CDC toggle below. **Neither
    // reproduced in simulation.** Driving miner_top with target=all-ones
    // (so every hash "wins") from reset, iverilog measured:
    //
    //     during warm-up (206 cycles): ticket2moon === 1'b0 for all of
    //         them; 0 cycles at 1, and 0 cycles at X (so the 0 is a real
    //         0, not an X that `if (ticket2moon)` silently read as false)
    //     after warm-up: 48 assertions over ~200 cycles -- one per
    //         THROUGHPUT(4)-cycle result slot -- each exactly 1 cycle
    //         long, never 2+ consecutive
    //
    // i.e. in that test the raw signal already behaved as a clean, warm-up
    // -respecting one-shot, and this gating is a measured no-op. It is
    // kept because the reference authors put it there and this file claims
    // to mirror them, and because it is provably unable to do harm (see
    // the 205-vs-204 note below). Reverting it would also be defensible;
    // what is NOT defensible is leaving the earlier commit message's
    // claim that it "could stall the miner" standing, since the evidence
    // does not support that.
    //
    // cou_deltanonce_top counts every clk_h cycle up to 8'hcd (205), which
    // is the same warm-up interval miner.v expresses internally as 6'h33
    // (51) counts of `advance` (51 x THROUGHPUT(4) = 204). Kept byte-for-
    // byte identical to the reference rather than re-derived.
    //
    // That 205-vs-204 relationship is why this gate cannot lose a real
    // solution: miner.v does not validly capture a nonce until its own
    // 204-cycle qualifier is met, so a nonce suppressed by opening this
    // gate one cycle later was never a nonce miner.v would have reported.
    // -----------------------------------------------------------------
    reg [7:0] cou_deltanonce_top = 8'h0;
    reg       nonce_out_go_top   = 1'b0;
    reg       ticket2moon_i      = 1'b0;

    always @(posedge clk_h)
        if (~start_hash_h) cou_deltanonce_top <= 8'h0;
        else               cou_deltanonce_top <= cou_deltanonce_top + 1'b1;

    always @(posedge clk_h)
        if (~start_hash_h)                    nonce_out_go_top <= 1'b0;
        else if (cou_deltanonce_top == 8'hcd) nonce_out_go_top <= 1'b1;

    always @(posedge clk_h)
        ticket2moon_i <= ticket2moon & nonce_out_go_top;

    // One-shot on top of the reference's gating. This wrapper -- unlike
    // the reference, which ships results over FX3 -- hands the nonce
    // across a clock domain using the two-phase toggle below. If
    // ticket2moon_i were ever high for 2+ consecutive cycles, flipping the
    // toggle on the level would flip it once per cycle, and the bus-side
    // 2-flop synchroniser would be sampling a signal changing faster than
    // it can track (golden_nonce_latch_h moving while captured = a torn
    // nonce). Measured longest run in simulation was exactly 1 cycle, so
    // today this is equivalent to the level-triggered version -- it makes
    // the one-shot assumption explicit and enforced rather than relying on
    // odo_keccak's comparator continuing to behave that way.
    reg  ticket2moon_i_d = 1'b0;
    always @(posedge clk_h) ticket2moon_i_d <= ticket2moon_i;
    wire ticket2moon_rise = ticket2moon_i & ~ticket2moon_i_d;

    // -----------------------------------------------------------------
    // Result latch + clk_h -> bus_clk status/nonce synchronization.
    // Same "accepted race on a status/telemetry register" simplification
    // as the Zynq wrapper -- see its comments for the rationale.
    // -----------------------------------------------------------------
    reg        nonce_toggle_h;
    reg [31:0] golden_nonce_latch_h;

    always @(posedge clk_h) begin
        if (ticket2moon_rise) begin
            golden_nonce_latch_h <= golden_nonce_h;
            nonce_toggle_h       <= ~nonce_toggle_h;
        end
    end

    (* ASYNC_REG = "TRUE" *) reg nonce_sync1_bus;
    reg nonce_sync2_bus, nonce_sync3_bus;
    (* ASYNC_REG = "TRUE" *) reg hash_active_sync1_bus;
    reg hash_active_sync2_bus;
    reg [31:0] golden_nonce_reg;
    reg        nonce_valid_reg;

    wire nonce_new_pulse_bus = nonce_sync2_bus ^ nonce_sync3_bus;

    // Synchronous reset deliberately -- see the sync-vs-async note above
    // wr_sync/rd_sync's always block; same reasoning applies here.
    always @(posedge bus_clk) begin
        if (!bus_rst_n) begin
            nonce_sync1_bus <= 1'b0;
            nonce_sync2_bus <= 1'b0;
            nonce_sync3_bus <= 1'b0;
            hash_active_sync1_bus <= 1'b0;
            hash_active_sync2_bus <= 1'b0;
            nonce_valid_reg <= 1'b0;
            golden_nonce_reg <= 32'h0;
        end else begin
            nonce_sync1_bus <= nonce_toggle_h;
            nonce_sync2_bus <= nonce_sync1_bus;
            nonce_sync3_bus <= nonce_sync2_bus;

            hash_active_sync1_bus <= start_hash_h;
            hash_active_sync2_bus <= hash_active_sync1_bus;

            if (nonce_new_pulse_bus) begin
                golden_nonce_reg <= golden_nonce_latch_h;
                nonce_valid_reg  <= 1'b1;
            end else if (nonce_valid_clear_pulse) begin
                nonce_valid_reg  <= 1'b0;
            end
        end
    end

    assign hash_active_bus  = hash_active_sync2_bus;
    assign nonce_valid_bus  = nonce_valid_reg;
    assign golden_nonce_bus = golden_nonce_reg;
    assign gpio_irq         = nonce_valid_reg;

endmodule
