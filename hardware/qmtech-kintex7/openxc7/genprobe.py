#!/usr/bin/env python3
"""Emit a probe design: N encrypt_4full_round stages chained through state
registers, mirroring encrypt_4encrypt_loop's structure (address = pbox0 of a
flip-flop) but with only 3 I/O pins so it fits the package."""
import sys
n = int(sys.argv[1])
L = ["module probe(input clk, input seed, output reg q);",
     "    reg [639:0] s0 = 640'b0;",
     "    always @(posedge clk) s0 <= {s0[638:0], seed};"]
for i in range(n):
    L.append(f"    wire [639:0] n{i};")
    L.append(f"    reg  [639:0] s{i+1} = 640'b0;")
for i in range(n):
    # instance name round<i> -- same naming encrypt_4encrypt_loop uses
    L.append(f"    encrypt_4full_round round{i}(clk, 10'h{(0x155*(i+1))&0x3ff:03x}, s{i}, n{i});")
    L.append(f"    always @(posedge clk) s{i+1} <= n{i};")
L.append(f"    always @(posedge clk) q <= ^s{n};")
L.append("endmodule")
open(f"probe{n}.v","w").write("\n".join(L)+"\n")
open(f"probe{n}.xdc","w").write(
    "set_property IOSTANDARD LVCMOS33 [get_ports clk]\n"
    "set_property PACKAGE_PIN F22 [get_ports clk]\n"
    "set_property IOSTANDARD LVCMOS33 [get_ports seed]\n"
    "set_property PACKAGE_PIN K18 [get_ports seed]\n"
    "set_property IOSTANDARD LVCMOS33 [get_ports q]\n"
    "set_property PACKAGE_PIN M20 [get_ports q]\n"
    "create_clock -period 10.000 -name clk [get_ports clk]\n")
print(f"probe{n}.v: {n} rounds, {n*20} expected RAMB18, 3 pins")
