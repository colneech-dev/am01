#!/usr/bin/env python3
"""Extract constraints for the 2 failing SRLC32E cells."""

import re

xdc_path = "out_nm1_nosr/nextpnr_placement_v68.xdc"

failing_cells = [
    "$auto$ff.cc:337:slice$226003.genblk2.genblk1.genblk1.genblk1.genblk1.genblk1.genblk1.genblk1.genblk1.genblk1[0].fpga_srl.genblk2.genblk1.genblk1.genblk1.genblk1.genblk1.genblk1.fpga_srl_0",
    "$auto$ff.cc:337:slice$226003.genblk2.genblk1.genblk1.genblk1.genblk1.genblk1.genblk1.genblk1.genblk1.genblk1[0].fpga_srl.genblk2.genblk1.genblk1.genblk1.genblk1.genblk1.genblk1.fpga_srl_1",
]

with open(xdc_path) as f:
    content = f.read()

print("# Hand-place constraints for the 2 SRLC32E cells that Vivado's packer can't handle\n")

for cell in failing_cells:
    # Find LOC and BEL constraints for this exact cell
    pattern = re.escape(cell)

    loc_matches = re.findall(
        f'set_property LOC ([A-Z0-9_]+) \\[get_cells {{.*{pattern}.*}}\\]',
        content
    )
    bel_matches = re.findall(
        f'set_property BEL ([A-Z0-9_]+) \\[get_cells {{.*{pattern}.*}}\\]',
        content
    )

    if loc_matches or bel_matches:
        print(f"# Cell: {cell}")
        if loc_matches:
            print(f"set_property LOC {loc_matches[0]} [get_cells {{{cell}}}]")
        if bel_matches:
            print(f"set_property BEL {bel_matches[0]} [get_cells {{{cell}}}]")
        print()
