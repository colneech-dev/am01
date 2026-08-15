# Vendor reference documents

Everything under this directory is copied unmodified from the QMTECH
vendor repo for this exact board, for offline reference while working on
`hardware/qmtech-kintex7/`.

- Upstream: https://github.com/ChinaQMTECH/QMTECH_Kintex-7_Development_Board
- Copied: 2026-08-15, from the `main` branch.
- Scope: the manuals, schematic, board dimension drawing, and the
  board-specific component/chip datasheets from the upstream repo's
  `Datasheet/` and `hardware/` folders. **Deliberately not copied**:
  `Datasheet/XC7K325T/*.pdf` (AMD/Xilinx's own general 7-series
  documentation) and `Datasheet/RPi_CM4/*.pdf` (Raspberry Pi Ltd.'s own
  general CM4/CM4-IO-Board documentation) — both are generic vendor docs
  available directly from docs.amd.com and raspberrypi.com respectively,
  not specific to this board, and together were ~108MB of this
  directory's original ~122MB. Also not copied: the
  `software/Test_Examples_with_RPi_CM4.../` folder (test-result images
  and captured waveforms from QMTECH's own bring-up, not reference docs).

## Layout

- `QMTECH_Kintex-7_XC7K325T_Development_Board_User_Manual*.pdf` — the two
  top-level manuals (a general one and a hardware-specific one).
- `hardware/QMTECH-XC7K325T-DEVELOPMENT-BOARD_SCHEMATIC_20231120_V01.pdf`
  — full board schematic (5 sheets: DDR3, CM4/USB/HDMI/SD peripherals,
  FPGA JTAG/config/SD-flash/PMODs, MGT transceivers, power).
  **This is what settled the JTAG-via-CM4-GPIO question**: the FPGA's
  JTAG pins (`TCK_0`/`TMS_0`/`TDO_0`/`TDI_0`) go to a standalone 6-pin
  header (`J1`), not to any `GPIO0`-`GPIO27` net — the CM4 socket has no
  path to it. `PROGRAM_B`/`DONE` are wired to an on-board button/LED
  (`SW2`/`LED2`, `LED3`) though, independent of both JTAG and the CM4.
- `hardware/Dimension(Board_Top_View).pdf` — mechanical drawing.
- `Datasheet/*.pdf` — component datasheets for parts used on this board
  (USB hub/mux, level shifters, power ICs, connectors). For AMD/Xilinx's
  general 7-series documentation or Raspberry Pi's general CM4
  documentation, go to docs.amd.com / raspberrypi.com directly — not
  duplicated here (see "Deliberately not copied" above).

## Licensing

Unmodified vendor/manufacturer documentation, copied as-is. Copyright
remains with the respective originators (QMTECH, AMD/Xilinx, Raspberry Pi
Ltd.) — kept here for project reference, not relicensed under this repo's
GPL-3.0-or-later.
