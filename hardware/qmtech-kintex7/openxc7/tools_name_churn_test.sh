#!/usr/bin/env bash
# Do yosys cell names survive an RTL edit?
#
# This decides whether a Vivado placement map keyed on those names can be
# committed and reused for future builds of this board, or whether it is a
# one-shot snapshot valid only for the exact netlist it was taken from.
#
# Design: two modules, identical except that v2 adds ONE unrelated gate at the
# END of the file. If names are positional/counter-based, cells that were not
# touched at all will still be renamed.
set -uo pipefail
cd /tmp
Y=~/oss-cad-suite/bin/yosys

cat > m1.v <<'EOF'
module m(input [7:0] a, input [7:0] b, input c, output [7:0] y, output z);
  assign y = (a ^ {a[6:0],a[7]}) & (b | {b[0],b[7:1]});
  assign z = 1'b0;
endmodule
EOF

# Same logic for y; one extra unrelated gate driving z.
cat > m2.v <<'EOF'
module m(input [7:0] a, input [7:0] b, input c, output [7:0] y, output z);
  assign y = (a ^ {a[6:0],a[7]}) & (b | {b[0],b[7:1]});
  assign z = c & a[0];
endmodule
EOF

for n in 1 2; do
  $Y -q -p "read_verilog m$n.v; synth_xilinx -family xc7 -top m; write_json m$n.json" 2>/dev/null
  grep -oE '\$abc\$[0-9]+\$auto\$[^"]*' m$n.json | sort -u > names$n.txt
done

echo "  v1 abc-named cells : $(wc -l < names1.txt)"
echo "  v2 abc-named cells : $(wc -l < names2.txt)"
echo "  names in BOTH      : $(comm -12 names1.txt names2.txt | wc -l)"
echo
echo "  v1 sample: $(head -1 names1.txt)"
echo "  v2 sample: $(head -1 names2.txt)"
