// QMTECH XC7K325T Dev Board -- two-part case (base tray + lid)
// Parametric OpenSCAD, 3D-print friendly (FDM, no supports needed).
// v4.1: REAL I/O, sourced from the vendor's own schematic + ECAD
// dimension drawing, not a photo guess. v4 was still wrong here --
// it put every connector on one wall as "estimates" and included a
// port (RJ45) that plain doesn't exist on this board. Fixed below;
// see note 0 for exactly what changed and why. FULLY ENCLOSED still
// holds (v3's open-top vented chimney stays gone -- uniform wall
// height everywhere, optional venting is a perforated lid panel, never
// an opening). This file is a shared template with two variant knobs
// (VARIANT_WALL_HEIGHT, VARIANT_VENTED) near the top; see ../README.md
// for the three generated variants (sealed / vented / tall-xl).
//
// Sources:
// - ChinaQMTECH/QMTECH_Kintex-7_Development_Board's own GitHub repo,
//   read directly for this revision (not just skimmed):
//   `QMTECH-XC7K325T-DEVELOPMENT-BOARD_SCHEMATIC_20231120_V01.pdf`
//   (5 sheets, real net names/ref-des) and
//   `hardware/Dimension(Board_Top_View).pdf` (real Allegro ECAD
//   placement export, rendered at 600dpi and read directly -- every
//   ref-des below (P3/P4, J6/J7/J9/J14, JP1/JP5/JP7/JP8, J11-J13, SW2-
//   SW4, U11) is a real component this board actually has, at
//   positions read off that drawing's own dimension lines/proportions,
//   not a manual cover-photo guess.
// - "QMTECH XC7K325T DEV BOARD USER MANUAL V01" for board outline
//   (160x90mm, matches the ECAD export) and general orientation.
// - colneech-dev/odo-miner-cyclonev's docs/DISPLAY_WIRING.md (display
//   module part number) and docs/FAN_SENSOR_WIRING.md (thermal sensor).
// - Ohmite/Arcol BGAH270-175E datasheet (27x27x17.5mm BGA heatsink,
//   sized for the exact 27x27mm body of this chip's FFG676 package).
//   Not available on AliExpress (distributor-only part -- RS/Digikey/
//   Mouser/Farnell/Enrgtech); see ../README.md for AliExpress
//   alternatives of the same class/size.
// - Raspberry Pi CM4 datasheet: two 100-pin B2B connector options,
//   1.5mm or 3.0mm mated stack height; module itself is 55x40x4.7mm.
//   Total height above the carrier board is ~6.2-7.7mm either way.
//
// ============================================================
// DESIGN DECISIONS -- read before printing
// ============================================================
// 0. WHAT CHANGED FROM v4 (real I/O, not estimates): reading the
//    vendor's actual schematic + ECAD drawing instead of guessing off
//    a manual photo turned up real errors, not just imprecision:
//      - RETRACTED, AND STILL A DEFECT: v4.1 claimed "this board has NO
//        Ethernet jack" and deleted the RJ45 cutout. That was wrong. The
//        HR911130A magjack IS populated -- it appears in every board
//        photograph in the user manual (Figure 2-3 and the CM4-docked
//        photo in section 2.2.9), and 2.2.9 lists "ethernet interface"
//        among the CM4 interfaces this board provides. Absence from one
//        placement drawing was treated as evidence of absence. The
//        cutout has NOT been restored yet -- doing that needs the jack's
//        real position, and this file has already been wrong once from
//        reading positions off a drawing. Measure it. Until then a
//        printed case covers the Ethernet port.
//      - There are FOUR USB-A ports, not two: J6 and J7 are each a
//        stacked "Dual USB-A" connector (2 ports per shell), driven by
//        a real USB2514QFN36 hub chip off the CM4's single USB2 OTG
//        line, plus a separate mini-USB (J14) for OTG/debug. v4 only
//        had "USB_1"/"USB_2" + one micro-USB.
//      - Every one of those (mini-USB + 4x USB-A) plus a 100-pin GPIO
//        expansion header (JP5) sit on the board's LONG bottom edge (y
//        near board_width), a wall v4 had ZERO cutouts on. v4 crammed
//        everything onto one wall; the real board uses three.
//      - The DC power jack (JP1) and power switch (SW4) are edge-
//        mounted at the TOP edge (y=0), not a lid-panel hole 20mm
//        inset like v4 had them -- a barrel jack's cable has to
//        approach from outside the case horizontally, not drop in from
//        above.
//      - The 3 general-purpose headers (J11/J12/J13, real ref-des, not
//        "HEADER_1/2/3") are genuinely lid-panel features (pins point
//        up) -- that part of v4 was actually right, positions nudged
//        slightly once real coordinates were available.
//      - Added SW2/SW3 (real user push-buttons, already referenced in
//        ../xdc/qmtech_xc7k325t_pinout.xdc) as small lid holes -- v4
//        didn't expose these at all.
//      - WALLS WEREN'T ACTUALLY FULL SIDES. Every wall cutout back to
//        v1 cut Z-height "wall_height + cutout_margin + 2" -- taller
//        than the wall itself, so every cutout notched through to the
//        wall's own top edge instead of being an enclosed window with
//        solid material above it. Harmless-looking with 1-2 small
//        cutouts; glaring once the real bottom wall got 4 cutouts,
//        several merging into one big open notch. Fixed: each cutout
//        now uses a real connector body height (4th field in the
//        position tables) and is capped by wall_cutout_h() so it never
//        eats into the last wall_roof_min_mm of the wall -- every side
//        keeps a genuinely continuous, full top edge.
//    Every position below is still oversized by cutout_margin -- these
//    are read off a dimensioned drawing now, not a photo, but "read off
//    a drawing" still isn't "measured with calipers on the real board".
// 1. TWO PARTS + THREE WALLS OF CUTOUTS: a base tray (board on a
//    perimeter lip) with cutouts on its LEFT wall (HDMI0/HDMI1/micro-
//    SD), BOTTOM wall (mini-USB + 4x USB-A + GPIO expansion header),
//    and TOP wall (DC jack + power switch) -- see left_edge_cutouts(),
//    bottom_edge_cutouts(), top_edge_cutouts() below -- plus a closed
//    LID with cutouts for the 3 general-purpose headers and 2 user
//    buttons. The lid seats on a friction skirt, secured with 4 corner
//    screws into full-height bosses (separate from the shorter
//    under-board standoffs).
// 2. NO CM4 CUTOUT. The CM4 mates via two 100-pin board-to-board
//    connectors (JP2/JP3) at 1.5-3.0mm stack height, and the module
//    itself is only 4.7mm thick -- total ~6.2-7.7mm above the carrier
//    board (Raspberry Pi CM4 datasheet). That's a fully internal,
//    low-profile mezzanine: its HDMI/USB/Ethernet-attempt/SD/GPIO
//    signals all route through JP2/JP3 to *this* board's own real
//    connectors (P3/P4/J6/J7/J9/J14/JP5), which the wall cutouts below
//    already handle. No panel access needed for JP2/JP3 themselves.
// 3. FULLY ENCLOSED, UNIFORM HEIGHT. wall_height is set directly (not
//    derived from a chimney calculation) to fully contain the real
//    heatsink (Ohmite/Arcol BGAH270-175E, 17.5mm) everywhere in the
//    case, not just over the FPGA -- see heatsink_total_clearance_mm's
//    derivation below, still traceable to the real part, just applied
//    uniformly instead of as a stepped chimney. VARIANT_WALL_HEIGHT
//    (set near the top) picks which of the 3 generated variants this
//    file becomes when exported.
// 4. VENTING IS OPTIONAL, NEVER AN OPEN HOLE ABOVE THE HEATSINK.
//    VARIANT_VENTED, if true, adds a grid of small (3mm) drilled vent
//    holes through the solid lid over the FPGA -- a perforated panel,
//    not a bore-through opening like v3's chimney. If false, that
//    region of the lid is completely solid: zero venting anywhere.
// 5. HOLE POSITIONS ARE READ OFF A REAL DRAWING, STILL NOT MEASURED.
//    Every position below comes from the vendor's own dimensioned ECAD
//    top-view (see Sources above), cross-referenced against the real
//    schematic's ref-des and net names -- a different tier of
//    confidence than v1-v4's photo-proportional guessing, but still
//    not calipers-on-the-actual-board precision. Every cutout is
//    deliberately oversized (cutout_margin) to absorb that. Nudge the
//    position tables below once you have the board.
// 6. DISPLAY: sized for the **KMRTM28028-SPI** (2.8" 240x320 ILI9341 +
//    XPT2242 touch, 14-pin header) -- the exact module
//    colneech-dev/odo-miner-cyclonev verified on real hardware for this
//    class of build. Mounted portrait (rotated 90 deg from its natural
//    orientation) in the lid's left region, the only area with enough
//    free space once the header cluster and the FPGA vent zone are
//    laid out -- verified by explicit numeric range-checking, not
//    eyeballing a render. This board's manual doesn't mention a
//    display; wiring it needs the board's 100-pin GPIO expansion header
//    (JP5, on the bottom wall -- see note 0) or spare CM4 GPIO lines --
//    SPI needs more signal lines (CS/DC/RST/SCLK/MOSI/MISO + touch
//    CS/IRQ) than the 4 spare CM4 lines (GPIO24-27, unused by
//    ../hdl/odocrypt_gpio_wrapper.v) provide, so JP5 is the realistic
//    path -- and now has a real cutout to route a cable through
//    (GPIO_HDR_JP5 in bottom_connector_positions_mm), which v4 didn't.
//    RTL/driver for this is NOT implemented anywhere in this repo yet
//    -- this file only adds the physical mounting provision.
// 7. THERMAL SENSOR: a DS18B20 (TO-92, 3-wire: VDD/GND/DATA), the same
//    part odo-miner-cyclonev uses, verified there tracking real load
//    (34-49 deg C). It mounts against/near the heatsink, not through a
//    panel cutout of its own size -- this lid just adds a small cable
//    pass-through hole near the FPGA vent zone for its 3 wires to route
//    out to JP5 or a spare CM4 GPIO.
// 8. Same square-corners note as v1-v4: `hull()`-based rounding
//    previously broke cutout subtraction silently -- confirmed by A/B
//    vertex-count testing. This file never used rounding to begin with.
// 9. Print a fit-check first, same as v1-v4 -- see note 5.
// ============================================================

// ============================================================
// VARIANT KNOBS -- these two lines are all that differ between the
// three generated files in ../v4-sealed/, ../v4-vented/, ../v4-tall-xl/.
// ============================================================
VARIANT_WALL_HEIGHT = 24;   // VENTED variant: perforated lid panel over the FPGA
VARIANT_VENTED       = true;  // VENTED variant: perforated lid panel over the FPGA

// ---- Board ----
board_length    = 160;   // X, the manual's Figure 2-1 dimension
board_width     = 90;    // Y
board_thickness = 1.6;   // standard PCB thickness

// ---- Fit tolerances ----
// 0.6 was too tight to actually assemble: across a 160mm span, FDM
// shrinkage plus elephant's foot on the first layers eats most of it, and
// the board fouls the walls before it reaches the lip. 1.2mm per side is
// still a snug fit and leaves the lip plenty of overlap (lip_ledge 1.5).
fit_gap        = 1.2;    // extra clearance around the board footprint, all sides
// The lip must reach past the board's edge by more than fit_gap, or there
// is nothing under the board to carry it. At fit_gap 1.2 a 1.5mm ledge
// would leave only 0.3mm of bearing surface; 3.0 leaves 1.8mm all round.
lip_ledge      = 3.0;    // how far the lip reaches in from the inner wall face
lip_thickness  = 2.0;    // Z height of the lip step the board rests on

// ---- Tray shell ----
wall_thickness  = 2.4;
floor_thickness = 2.4;
standoff_clearance = 3.0;   // gap under the board for bottom-side components/solder

// Case interior height, uniform everywhere (fully enclosed -- see design
// note 3 above). Set directly by VARIANT_WALL_HEIGHT; also cross-checked
// below against the real heatsink dimensions so you can see the margin
// (or shortfall) rather than trust a bare constant.
wall_height = VARIANT_WALL_HEIGHT;
lid_thickness = 2.4;

// ---- FPGA/heatsink clearance check (informational + drives the vent
// hole footprint below) ----------------------------------------------
// Ohmite/Arcol BGAH270-175E, 27x27x17.5mm -- dimensioned for exactly
// this chip's FFG676 package body (27x27mm). Not on AliExpress
// (distributor-only part); see ../README.md for same-class alternatives
// actually sold there. Position read directly off U11's real BGA
// footprint (pin columns 1-26, rows A-AF) in
// hardware/Dimension(Board_Top_View).pdf in
// ChinaQMTECH/QMTECH_Kintex-7_Development_Board (vendor's own ECAD
// dimension export) -- centered in the free area between the JP2/JP3
// mezzanine connectors and the J11-J13 header row, still read off a
// drawing rather than measured, but a real footprint now, not "roughly
// the board's center".
heatsink_lwh_mm       = [27, 27, 17.5]; // BGAH270-175E, L x W x H
heatsink_center_mm    = [117, 45];      // FPGA package center, board-local XY
heatsink_xy_margin_mm = 8;              // clearance around the heatsink body,
                                         // each side (position uncertainty +
                                         // the heatsink's own mounting clips)
fpga_chip_and_pad_mm  = 2.0;  // BGA body + thermal pad, above the PCB surface
heatsink_assembly_margin_mm = 3.0; // safety margin (adhesive squeeze-out, tolerance)
heatsink_total_clearance_mm = heatsink_lwh_mm[2] + fpga_chip_and_pad_mm
                               + heatsink_assembly_margin_mm; // = 22.5mm, PCB to top of stack
case_interior_clearance_mm  = wall_height + lid_thickness; // what this variant actually provides
heatsink_margin_mm = case_interior_clearance_mm - heatsink_total_clearance_mm; // sanity check;
                      // should be comfortably positive -- echoed at the bottom of this file

// Footprint the vent-hole grid (if VARIANT_VENTED) is centered on --
// oversized around the heatsink body the same way the old chimney was.
vent_zone_mm = [heatsink_lwh_mm[0] + 2*heatsink_xy_margin_mm,
                 heatsink_lwh_mm[1] + 2*heatsink_xy_margin_mm]; // = [43,43]
vent_hole_d       = 3;
vent_hole_pitch   = 7; // center-to-center spacing

// ---- Lid ----
lid_skirt_depth = 3.0;   // how far the lid's alignment skirt reaches down inside the tray
lid_fit_clearance = 0.3; // per-side gap between skirt and tray inner wall

// ---- Corner standoffs (board support, short -- see v1 note 3) ----
// OFF by default now. These were placed at a generic 5mm inset that was
// never transcribed from the dimension drawing (old design note 7 admitted
// as much). The real board's mounting holes are on an 82.4mm vertical
// pitch (Dimension(Board_Top_View).pdf), i.e. 3.8mm in from the top and
// bottom edges -- so a 6mm-diameter post at a 5mm inset misses the hole
// and lands on the underside of the PCB instead, holding the board up
// rather than locating it. The perimeter lip already retains the board on
// all four sides, which is what design note 7 calls primary retention.
// Re-enable only after measuring your own board's hole positions, and set
// standoff_xy_mm to them.
// MEASURED, 2026-08-29, from Dimension(Board_Top_View).pdf rendered at
// 600dpi and analysed numerically (not read by eye -- that is how the I/O
// positions went wrong). Calibration: the board outline resolves to a
// 472x266px rectangle, aspect 1.774 vs the true 160/90 = 1.7778 (0.19%
// error), giving 0.3387 mm/px -- exactly 600dpi/8, which is the check that
// the scale is real.
//   mounting hole pads:  5.42mm diameter
//   vertical pitch:      82.40mm measured vs 82.4mm printed on the drawing
//   so the holes sit 3.89mm and 3.72mm in from the top and bottom edges
// The X positions are NOT recorded because only 4 of the ~6 holes could be
// separated -- the corner ones merge into the board outline during
// connected-component analysis. That is why this stays off: a partial hole
// set is exactly the kind of half-known number that produced the original
// bug. Measure your board's holes with calipers and fill in standoff_xy_mm.
// ON, at MEASURED positions. The four corner holes are now known well
// enough to sit a standoff under each.
//
// Derived from Dimension(Board_Top_View).pdf analysed numerically (see the
// MEASURED note above), and cross-checked three ways rather than trusted:
//   - the hole chain along the top reproduces the drawing's own printed
//     dimensions to within 0.05mm: gaps of 26.38 / 32.97 / 16.86 / 76.22
//     against a printed 26.4 / 33 / 16.8 / 76.2;
//   - the vertical span measures 82.40mm against a printed 82.4;
//   - the corners come out symmetric about both axes -- 3.70 and
//     160-156.13=3.87 in X, 3.89 and 90-86.28=3.72 in Y -- which is what a
//     four-corner pattern must look like and is not something a
//     mis-detection would produce by chance.
// Taken together that is a real measurement, not the "roughly the board
// centre" guessing that produced the earlier faults.
//
// SIX holes: four corners plus the two mid-span ones, confirmed against the
// board. x=80.0 is arrived at three independent ways, which is why it is
// trusted: it is 76.2 out from the left corner (3.8+76.2), 76.2 back from the
// right one (156.2-76.2), and exactly half of the 160mm board. 76.2 is itself
// a dimension PRINTED on the drawing, and the numeric detection independently
// put a hole at 79.91.
//
// The drawing shows further holes along the top edge at x=30.08 and 63.05
// with no matching pair on the bottom edge, so they are left alone: a
// standoff is only useful where its position is certain, and one landing on a
// bottom-side component lifts the board -- worse than no standoff at all.
//
// These are FLAT-TOPPED bosses with a pilot hole drilled through, not pegs
// that locate in the board's holes -- see corner_standoff(). That is
// deliberate. A locating peg is only as good as the position it is placed
// at, and a peg that misses its hole jams against the board and holds it
// proud, which is precisely how the v4.1 lid-screw bosses stopped the case
// closing. A flat boss under an approximately-right position still just
// supports the board. The pilot takes an M3 self-tap from underneath if you
// want the board positively retained once you have confirmed the holes.
enable_standoffs   = true;
standoff_xy_mm     = [[3.8, 3.8],  [80.0, 3.8],  [156.2, 3.8],
                      [3.8, 86.2], [80.0, 86.2], [156.2, 86.2]];
standoff_inset_mm  = 5;    // fallback only, used when standoff_xy_mm is empty
standoff_od        = 5.0;  // sits inside the 5.42mm pad seen on the drawing
standoff_pilot_od  = 2.6;

// ---- Corner lid-screw bosses -----------------------------------------
// These are now EXTERNAL ears, outside the case walls.
//
// They used to sit at boss_inset = wall_thickness + 3 = 5.4mm in from the
// outer edge, as full-height (wall_height + floor_thickness) pillars. With
// board_origin at wall_thickness + fit_gap, that put a 7mm-diameter pillar
// centre only 3.39mm from the board's own corner -- less than its 3.5mm
// radius. Each of the four bosses therefore stood about 1.1mm inside the
// board's footprint, floor to lid. A rigid PCB with square corners cannot
// be lowered past four such pillars: this is why the board would not go
// into the tray, and why it then sat proud and stopped the lid closing.
// The old comment ("bosses sit just inside the wall corners") reasoned
// about boss-vs-standoff interference and never checked boss-vs-board.
//
// Moving the boss centres 1mm OUTSIDE each case corner puts them 4.81mm
// from the interior corner and 5.66mm from the board corner, both
// comfortably clear of the 3.5mm radius, while still overlapping the
// corner solidly enough to fuse to the wall. Nothing intrudes on the
// interior at all now.
boss_od       = 7.0;
boss_pilot_od = 2.6;   // M3 self-tap/heat-set pilot
boss_ear_offset = 1.0; // how far outside each case corner the boss centre sits
lid_screw_clearance_od = 3.4; // clearance hole through the lid itself

// ---- Wall cutouts: THREE walls carry real connectors (see design note
// 0 -- v4 wrongly put everything on one wall). All positions read off
// hardware/Dimension(Board_Top_View).pdf (ChinaQMTECH/QMTECH_Kintex-7_
// Development_Board's real Allegro ECAD export) cross-referenced
// against the real schematic's ref-des
// (QMTECH-XC7K325T-DEVELOPMENT-BOARD_SCHEMATIC_20231120_V01.pdf).
cutout_margin = 3.0;

// LEFT wall (x=0, board_width=90mm long): HDMI0 (P3) and HDMI1 (P4),
// both Type-A jacks mounted flush to this edge stacked vertically, plus
// the micro-SD slot (J9) below them. [name, y_center, footprint_len,
// cutout_height_above_board] -- the 4th field caps how tall the cutout
// is, so it stays a real enclosed window instead of notching all the
// way up to the wall's own top edge (that was v1-v4's behavior on every
// wall cutout: "not full sides" -- fixed here, see design note 0b).
// Heights are generous-but-realistic connector body heights, not a
// datasheet measurement.
connector_positions_mm = [
    ["HDMI0_P3",    22, 16, 13],
    ["HDMI1_P4",    41, 16, 13],
    ["MICRO_SD_J9", 65, 14,  5],
];

// BOTTOM wall (y=board_width, board_length=160mm long): mini-USB (J14,
// OTG/debug) then two stacked dual-USB-A connectors (J6, J7 -- 4 ports
// total, driven by a real USB2514QFN36 hub off the CM4's single USB2
// line) then the 100-pin GPIO expansion header (JP5) -- a real, wide
// window so a display/sensor cable can actually route out through it
// (see design note 6). v4 had NONE of this: zero cutouts on this wall.
// [name, x_center, width, cutout_height_above_board]
bottom_connector_positions_mm = [
    ["MINI_USB_J14",  14, 12,  6],
    ["USB_A_J6",      31, 18, 17],   // 2 stacked USB-A ports
    ["USB_A_J7",      51, 18, 17],   // 2 more stacked USB-A ports
    ["GPIO_HDR_JP5", 119, 58, 12],   // cable pass-through, not a connector body
];

// TOP wall (y=0, board_length=160mm long): DC barrel jack (JP1) only --
// edge-mounted, cable approaches from outside the case horizontally, so
// this is a WALL cutout (round hole through top_edge_dc_jack() below),
// not a lid-panel hole like v4 had it. JP8 (a jumper next to JP1) and
// the general power-switch/user-button cluster are internal or lid
// features -- see lid_top_cutouts_mm below. No rectangular top-wall
// cutouts are needed right now (top_edge_cutouts() stays here, empty,
// for symmetry with the other two walls in case a future revision
// needs one), so the DC jack gets its own round-hole module below
// instead of going through that generic array.
top_connector_positions_mm = [];
dc_jack_x_mm     = 154; // JP1, board-local X on the top wall (y=0)
dc_jack_diameter = 12;

// ---- Lid cutouts: features that mount with pins/actuators pointing UP
// through the board, accessed from directly above (X,Y = top-left
// corner of the window, offset from the board's own origin same as the
// board footprint below). [name, x, y, w, h]. J11/J12/J13 are real
// 2x6 general-purpose headers (PMOD-compatible pitch) along the top
// edge; SW4 is a real slide power switch (SS12D06) mounted flat on the
// PCB with its actuator tab facing up -- a lid slot, not a wall cutout
// (it doesn't sit flush against the y=0 edge). SW2/SW3 are real user
// push-buttons already referenced in ../xdc/qmtech_xc7k325t_pinout.xdc
// -- v4 didn't expose these at all.
lid_top_cutouts_mm = [
    ["J11", 90,  0, 16, 12],
    ["J12", 110, 0, 16, 12],
    ["J13", 130, 0, 16, 12],
    ["SW4", 148, 14, 12, 8],
];
// Small round holes for the two user push-buttons (SW2/SW3), near JP5
// on the board's lower-right, above the bottom-wall GPIO header window.
lid_button_positions_mm = [
    ["SW2", 144, 72],
    ["SW3", 151, 72],
];
lid_button_d = 6;

// Ventilation, if VARIANT_VENTED, is a grid of small drilled holes
// straight through the solid lid over the FPGA (see
// lid_fpga_vent_holes() below) -- a perforated panel, not an open
// chimney: the box stays fully enclosed either way, this variant knob
// only decides whether that one region is solid or perforated.

// DS18B20 sensor cable pass-through, tucked into the gap between the
// display and the FPGA vent zone (checked clear of both below).
sensor_hole_center_mm = [70, 50];
sensor_hole_d = 5;

// ---- Display mounting (KMRTM28028-SPI 2.8" ILI9341+XPT2046, see design
// note 5 at the top of this file). Module PCB footprint/hole-spacing
// below are TYPICAL for this class of 14-pin 2.8" SPI TFT module
// family, not this exact module's datasheet dimensions -- verify
// against your actual module before printing.
//
// Mounted PORTRAIT (rotated 90 deg from the module's natural landscape
// orientation) in the freed-up left region of the lid -- the only area
// with enough room once the J11-J13 header row (y<12) and the FPGA
// vent zone (x=95.5-138.5, y=23.5-66.5, derived from the real
// heatsink_center_mm above) are laid out. Explicitly checked, not
// eyeballed:
//   PCB footprint  x=[8.5,61.5]  y=[7,83]   -- clear of vent zone (61.5 < 95.5)
//   Active cutout  x=[13,57]     y=[16,74]  -- within board 0-160 x 0-90
//   Mount holes    x=[11.5,58.5] y=[10,80]
display_pcb_mm       = [53, 76];  // W x H, ROTATED from the module's native 76x53
display_active_mm    = [44, 58];  // ditto, rotated
display_hole_spacing_mm = [47, 70]; // ditto, rotated
display_center_mm    = [35, 45];  // left region of the lid, clear of vent zone/headers
display_standoff_od  = 6.0;
display_standoff_ht  = 4.0;       // clears the module's underside components
display_screw_pilot_od = 2.2;     // M2/M2.5 self-tap pilot

// ============================================================
// Derived geometry
// ============================================================
outer_length = board_length + 2*(fit_gap + wall_thickness);
outer_width  = board_width  + 2*(fit_gap + wall_thickness);
tray_height  = floor_thickness + standoff_clearance + board_thickness + wall_height;
lip_z = floor_thickness + standoff_clearance; // board rests here
board_origin = [wall_thickness + fit_gap, wall_thickness + fit_gap]; // XY of board's own (0,0)

// Lid-screw boss centres: one per corner, boss_ear_offset OUTSIDE the case
// so nothing reaches into the board's footprint. Defined once and used by
// both the tray (solid bosses) and the lid (matching ears + clearance
// holes) -- the old code hardcoded "wall_thickness + 3" separately in each
// of those two places, so the tray and lid could drift apart silently.
boss_positions = [
    [-boss_ear_offset,                -boss_ear_offset],
    [outer_length + boss_ear_offset,  -boss_ear_offset],
    [-boss_ear_offset,                outer_width + boss_ear_offset],
    [outer_length + boss_ear_offset,  outer_width + boss_ear_offset],
];

// ---- Base tray -----------------------------------------------------

module tray_shell() {
    difference() {
        linear_extrude(height = tray_height)
            square([outer_length, outer_width]);
        translate([wall_thickness, wall_thickness, floor_thickness])
            linear_extrude(height = tray_height)
                square([outer_length - 2*wall_thickness,
                        outer_width  - 2*wall_thickness]);
    }
}

// The ledge the board actually rests on, running the full perimeter.
//
// This was a no-op in every version up to now. It built its ring between
// inset = wall_thickness - lip_ledge (0.9mm) and wall_thickness (2.4mm) --
// entirely WITHIN the wall's own 0..2.4mm thickness, so it added no
// material to the interior and supported nothing. It was also extruded
// upward FROM lip_z, i.e. level with the board rather than beneath it.
// With the lip doing nothing, the board's only support was the four corner
// standoffs, which are themselves at an unverified position (see
// enable_standoffs above) -- so the board had no reliable seat at all.
//
// Correct now: the ring runs inward from the inner wall face by lip_ledge,
// and sits directly BELOW lip_z so the board's underside lands on it.
module retaining_lip_ridge() {
    // The outer rectangle deliberately spans the WHOLE footprint rather
    // than starting at the inner wall face. Starting it exactly at
    // wall_thickness would leave the lip touching the wall on a single
    // coincident plane, which is the same CGAL non-fusion trap that
    // corner_standoff()/lid_screw_boss()/lid_skirt() all use fuse_eps to
    // avoid -- it renders as two volumes that merely abut, not one solid.
    // Everything outside the inner wall face is inside wall material
    // anyway, so the overlap costs nothing.
    translate([0, 0, lip_z - lip_thickness])
    difference() {
        linear_extrude(height = lip_thickness)
            square([outer_length, outer_width]);
        translate([wall_thickness + lip_ledge, wall_thickness + lip_ledge, -1])
            linear_extrude(height = lip_thickness + 2)
                square([outer_length - 2*(wall_thickness + lip_ledge),
                        outer_width  - 2*(wall_thickness + lip_ledge)]);
    }
}

// Every wall cutout below is capped so it stays a real enclosed window,
// not a notch cut through to the wall's own top edge (that was v1-v4's
// behavior on every wall cutout -- "not full sides": walls looked open/
// notched rather than solid with discrete windows in them, especially
// once the real bottom-wall connectors got added). z0 starts a little
// below the board's resting surface (same -cutout_margin allowance as
// before); the height is the connector's real-ish body height plus
// margin on both ends, but never allowed to eat into wall_roof_min_mm
// of solid material below the wall's actual top -- so every wall keeps
// a full, continuous top edge above its windows.
wall_roof_min_mm = 3.0;
function wall_cutout_z0() = lip_z - cutout_margin;
function wall_cutout_h(body_h) =
    min(body_h + 2*cutout_margin,
        (tray_height - wall_roof_min_mm) - wall_cutout_z0());

module left_edge_cutouts() {
    for (c = connector_positions_mm) {
        y_center = board_origin[1] + c[1];
        h = c[2] + 2*cutout_margin;
        translate([-1, y_center - h/2, wall_cutout_z0()])
            cube([wall_thickness + 2, h, wall_cutout_h(c[3])]);
    }
}

// BOTTOM wall (y=outer_width side): mini-USB, 2x dual-USB-A, GPIO
// expansion header -- see bottom_connector_positions_mm above. Same
// oversized-rectangle-through-the-wall approach as left_edge_cutouts(),
// now also height-capped the same way.
module bottom_edge_cutouts() {
    for (c = bottom_connector_positions_mm) {
        x_center = board_origin[0] + c[1];
        w = c[2] + 2*cutout_margin;
        translate([x_center - w/2, outer_width - wall_thickness - 1, wall_cutout_z0()])
            cube([w, wall_thickness + 2, wall_cutout_h(c[3])]);
    }
}

// TOP wall (y=0 side): reserved for any future rectangular top-wall
// cutouts (none currently -- the DC jack is round, see
// top_edge_dc_jack() below). Kept for symmetry with the other two
// edges and so top_connector_positions_mm has somewhere to plug in.
module top_edge_cutouts() {
    for (c = top_connector_positions_mm) {
        x_center = board_origin[0] + c[1];
        w = c[2] + 2*cutout_margin;
        translate([x_center - w/2, -1, wall_cutout_z0()])
            cube([w, wall_thickness + 2, wall_cutout_h(c[3])]);
    }
}

// The DC barrel jack (JP1) is round and edge-mounted -- cuts straight
// through the top wall (y=0) horizontally, at roughly the case's
// mid-height, rather than the oversized-rectangle treatment used for
// the other wall connectors (a barrel jack's round bezel reads cleanly
// as a round hole, and it's the one wall feature worth the extra
// module). See design note 0: this replaces v4's mistaken lid-panel
// hole 20mm inset from the edge.
module top_edge_dc_jack() {
    translate([board_origin[0] + dc_jack_x_mm, -1, lip_z + wall_height/2])
        rotate([-90, 0, 0])
            cylinder(h = wall_thickness + 2, d = dc_jack_diameter + cutout_margin, $fn = 32);
}

module corner_standoff(x, y) {
    fuse_eps = 0.05;
    translate([x, y, floor_thickness - fuse_eps])
        difference() {
            cylinder(h = standoff_clearance + fuse_eps, d = standoff_od, $fn = 32);
            translate([0,0,-1])
                cylinder(h = standoff_clearance + fuse_eps + 2, d = standoff_pilot_od, $fn = 24);
        }
}

function corner_xy(inset) = [
    [board_origin[0] + inset,               board_origin[1] + inset],
    [board_origin[0] + board_length - inset, board_origin[1] + inset],
    [board_origin[0] + inset,               board_origin[1] + board_width - inset],
    [board_origin[0] + board_length - inset, board_origin[1] + board_width - inset],
];

module standoffs() {
    if (enable_standoffs) {
        pts = len(standoff_xy_mm) > 0
            ? [ for (h = standoff_xy_mm) [board_origin[0] + h[0], board_origin[1] + h[1]] ]
            : corner_xy(standoff_inset_mm);
        for (p = pts)
            corner_standoff(p[0], p[1]);
    }
}

// Full-height bosses for the lid screws, on EXTERNAL corner ears. See the
// boss_ear_offset comment in the parameter block for why these are no
// longer inside the case: as internal corner pillars they stood ~1.1mm
// inside the board's own footprint and physically blocked the board from
// seating.
module lid_screw_boss(x, y) {
    fuse_eps = 0.05;
    translate([x, y, -fuse_eps])
        difference() {
            cylinder(h = wall_height + floor_thickness + fuse_eps, d = boss_od, $fn = 32);
            translate([0,0,-1])
                cylinder(h = wall_height + floor_thickness + fuse_eps + 2, d = boss_pilot_od, $fn = 24);
        }
}

module lid_screw_bosses() {
    for (p = boss_positions)
        lid_screw_boss(p[0], p[1]);
}

module base_tray() {
    union() {
        difference() {
            tray_shell();
            union() {
                left_edge_cutouts();
                bottom_edge_cutouts();
                top_edge_cutouts();
                top_edge_dc_jack();
            }
        }
        retaining_lip_ridge();
        standoffs();
        lid_screw_bosses();
    }
}

// ---- Lid -------------------------------------------------------------

module lid_panel() {
    linear_extrude(height = lid_thickness)
        square([outer_length, outer_width]);
}

module lid_skirt() {
    // A downward alignment/friction skirt, inset to fit just inside the
    // tray's inner wall opening. fuse_eps overlaps it into lid_panel by
    // a hair so CGAL fuses them into one solid instead of two coincident
    // touching faces (same fix as corner_standoff()/lid_screw_boss()).
    fuse_eps = 0.05;
    inset = wall_thickness + lid_fit_clearance;
    translate([0,0,-lid_skirt_depth])
        linear_extrude(height = lid_skirt_depth + fuse_eps)
            difference() {
                translate([inset, inset])
                    square([outer_length - 2*inset, outer_width - 2*inset]);
                translate([inset + wall_thickness, inset + wall_thickness])
                    square([outer_length - 2*(inset + wall_thickness),
                            outer_width  - 2*(inset + wall_thickness)]);
            }
}

// Matching ears on the lid, so the screws have something to pass through
// now that the bosses are outside the walls. Same boss_positions list as
// the tray, so the two halves cannot drift apart.
module lid_ears() {
    for (p = boss_positions)
        translate([p[0], p[1], 0])
            cylinder(h = lid_thickness, d = boss_od, $fn = 32);
}

module lid_screw_clearance_holes() {
    for (p = boss_positions)
        translate([p[0], p[1], -1])
            cylinder(h = lid_thickness + lid_skirt_depth + 2, d = lid_screw_clearance_od, $fn = 24);
}

module lid_top_edge_cutouts() {
    // Individual, discrete windows -- replaces v1's fully-open top edge.
    for (c = lid_top_cutouts_mm) {
        x0 = board_origin[0] + c[1] - cutout_margin;
        y0 = board_origin[1] + c[2] - cutout_margin;
        w  = c[3] + 2*cutout_margin;
        h  = c[4] + 2*cutout_margin;
        translate([x0, y0, -1])
            cube([w, h, lid_thickness + 2]);
    }
}

// Two small round holes for the real user push-buttons SW2/SW3 (see
// lid_button_positions_mm above) -- v4 didn't expose these at all.
module lid_buttons() {
    for (b = lid_button_positions_mm) {
        translate([board_origin[0] + b[1], board_origin[1] + b[2], -1])
            cylinder(h = lid_thickness + 2, d = lid_button_d + cutout_margin, $fn = 24);
    }
}

// ---- FPGA vent zone: EITHER nothing (fully solid lid, VARIANT_VENTED
// = false) OR a grid of small drilled holes through the solid lid
// (VARIANT_VENTED = true) -- see design note 4 at the top of this file.
// The case is fully enclosed either way: this never opens a hole big
// enough to expose the heatsink to open air, unlike v3's chimney.

module lid_fpga_vent_holes() {
    if (VARIANT_VENTED) {
        cx = board_origin[0] + heatsink_center_mm[0];
        cy = board_origin[1] + heatsink_center_mm[1];
        nx = max(1, floor(vent_zone_mm[0] / vent_hole_pitch));
        ny = max(1, floor(vent_zone_mm[1] / vent_hole_pitch));
        x0 = cx - (nx-1)*vent_hole_pitch/2;
        y0 = cy - (ny-1)*vent_hole_pitch/2;
        for (i = [0:nx-1])
            for (j = [0:ny-1])
                translate([x0 + i*vent_hole_pitch, y0 + j*vent_hole_pitch, -1])
                    cylinder(h = lid_thickness + 2, d = vent_hole_d, $fn = 16);
    }
}

module lid_sensor_passthrough() {
    translate([board_origin[0] + sensor_hole_center_mm[0],
                board_origin[1] + sensor_hole_center_mm[1], -1])
        cylinder(h = lid_thickness + 2, d = sensor_hole_d, $fn = 24);
}

module lid_display_cutout() {
    cx = board_origin[0] + display_center_mm[0];
    cy = board_origin[1] + display_center_mm[1];
    translate([cx - display_active_mm[0]/2, cy - display_active_mm[1]/2, -1])
        cube([display_active_mm[0], display_active_mm[1], lid_thickness + 2]);
}

module lid_display_standoffs() {
    fuse_eps = 0.05; // overlap into lid_panel, same reason as lid_skirt() above
    cx = board_origin[0] + display_center_mm[0];
    cy = board_origin[1] + display_center_mm[1];
    hx = display_hole_spacing_mm[0]/2;
    hy = display_hole_spacing_mm[1]/2;
    for (p = [[-hx,-hy],[hx,-hy],[-hx,hy],[hx,hy]])
        translate([cx + p[0], cy + p[1], lid_thickness - fuse_eps])
            difference() {
                cylinder(h = display_standoff_ht + fuse_eps, d = display_standoff_od, $fn = 24);
                translate([0,0,-1])
                    cylinder(h = display_standoff_ht + fuse_eps + 2, d = display_screw_pilot_od, $fn = 16);
            }
}

module lid() {
    union() {
        difference() {
            union() {
                lid_panel();
                lid_ears();
                lid_skirt();
            }
            lid_screw_clearance_holes();
            lid_top_edge_cutouts();
            lid_buttons();
            lid_fpga_vent_holes();
            lid_sensor_passthrough();
            lid_display_cutout();
        }
        lid_display_standoffs();
    }
}

// Sanity-check echo: confirms (at compile time, in the console/log) how
// much margin this variant's wall_height leaves over the real heatsink's
// needs. Should read comfortably positive.
echo(str("heatsink clearance margin (mm): ", heatsink_margin_mm,
         " [interior provides ", case_interior_clearance_mm,
         ", heatsink needs ", heatsink_total_clearance_mm, "]"));

// Assertion: no lid-screw boss may reach into the board's footprint.
// This is the bug that made the printed case unusable -- the bosses stood
// ~1.1mm inside the board's corners, full height, so the board could not
// be lowered in and the lid then would not close. An echo alone would have
// scrolled past unread, so this is a hard assert: the render FAILS rather
// than quietly producing an unassemblable STL again.
function _dist_to_board(p) =
    let (dx = max(board_origin[0] - p[0], 0, p[0] - (board_origin[0] + board_length)),
         dy = max(board_origin[1] - p[1], 0, p[1] - (board_origin[1] + board_width)))
    sqrt(dx*dx + dy*dy);

boss_min_gap = min([ for (p = boss_positions) _dist_to_board(p) ]) - boss_od/2;
echo(str("lid-screw boss clearance to board edge (mm): ", boss_min_gap));
assert(boss_min_gap > 0,
       str("lid-screw boss intrudes into the board footprint by ",
           -boss_min_gap, "mm -- the board cannot be fitted. ",
           "Increase boss_ear_offset or reduce boss_od."));

// Assertion: the lip must actually reach under the board. lip_ledge is
// measured from the inner wall face, and the board edge sits fit_gap in
// from that face, so the real bearing width is the difference. This was
// silently zero (worse: negative) before, which is how a lip that
// supported nothing survived four revisions.
// Assertion: the standoff tops and the lip top must be the SAME plane, so
// the board sits flat on whichever it touches.
//
// An earlier version of this assert demanded standoffs stay clear of the lip
// and failed at 0.5mm of overlap. That was the wrong invariant: both surfaces
// finish at lip_z by construction (corner_standoff starts at floor_thickness
// and is standoff_clearance tall; lip_z is floor_thickness +
// standoff_clearance), so an overlapping standoff simply merges into a
// thicker patch of ledge at the same height. Overlap is harmless. What would
// NOT be harmless is the two disagreeing in height -- a standoff even a
// fraction proud of the lip becomes a pivot and rocks the board.
standoff_top_z = floor_thickness + standoff_clearance;
echo(str("standoff top / lip top (mm): ", standoff_top_z, " / ", lip_z));
assert(abs(standoff_top_z - lip_z) < 0.001,
       str("standoff tops at ", standoff_top_z, " but the lip tops at ", lip_z,
           " -- the board would rock. These must be equal."));

lip_bearing_mm = lip_ledge - fit_gap;
echo(str("lip bearing width under board edge (mm): ", lip_bearing_mm));
assert(lip_bearing_mm >= 1.0,
       str("retaining lip only reaches ", lip_bearing_mm,
           "mm under the board edge -- not enough to carry it. ",
           "Increase lip_ledge or reduce fit_gap."));

// ============================================================
// Output: base tray and lid side by side, print-plate friendly.
// Comment either out to export just one part.
// ============================================================
base_tray();
translate([0, outer_width + 15, 0])
    lid();

// ---- Reference: board footprint ghost (preview only) ----
module board_ghost() {
    translate([board_origin[0], board_origin[1], lip_z])
        color([0,1,0,0.35])
        cube([board_length, board_width, board_thickness]);
}
%board_ghost();
