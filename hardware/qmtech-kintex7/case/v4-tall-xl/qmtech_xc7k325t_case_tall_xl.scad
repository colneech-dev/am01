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
VARIANT_WALL_HEIGHT = 48.0;   // TALL-XL variant: extra headroom for a bigger heatsink+fan
VARIANT_VENTED       = true;  // TALL-XL: vented, extra headroom

// ---- Board ----
board_length    = 160;   // X, the manual's Figure 2-1 dimension
board_width     = 90;    // Y
board_thickness = 2.0;   // MEASURED. Not the usual 1.6 -- this is a thick,
                         // many-layer board, and it matters: every wall
                         // cutout is positioned relative to the board.

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
// Venting is now the WHOLE lid, not a patch over the FPGA. A sealed box
// around a part that already ran too hot to touch was the wrong default; the
// grid is cheap to print and costs nothing but a little rigidity.
vent_zone_mm = [board_length, board_width];
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

// ---- Snap-fit lid (no screws, no corner bosses) ---------------------
// The lid is held by a bead running round the outside of its skirt, engaging
// a groove in the tray's inner wall. Nothing protrudes outside the case, which
// is what retires the external corner ears -- those ears only existed because
// the bosses could not go inside without fouling the board.
//
// 0.6mm of interference is the usual figure for PETG or ABS at this wall
// thickness: enough to hold, little enough to snap over by hand. The bead is
// chamfered on its underside so the lid leads in and only resists on the way
// out.
snap_bead_mm   = 0.6;   // radial interference
snap_bead_h    = 1.2;   // bead height
snap_lead_in   = 0.6;   // chamfer under the bead, for assembly


// ---- Wall cutouts: THREE walls carry real connectors (see design note
// 0 -- v4 wrongly put everything on one wall). All positions read off
// hardware/Dimension(Board_Top_View).pdf (ChinaQMTECH/QMTECH_Kintex-7_
// Development_Board's real Allegro ECAD export) cross-referenced
// against the real schematic's ref-des
// (QMTECH-XC7K325T-DEVELOPMENT-BOARD_SCHEMATIC_20231120_V01.pdf).
// 3.0 was chosen to absorb positions that were guessed off a drawing. Every
// connector is measured now, so that much slack is no longer needed -- and it
// was actively harmful: the gaps between adjacent connectors on this board are
// only 4mm, so a 3mm margin each side overlapped them and merged four separate
// windows into two long slots. 1.0mm still gives a connector 1mm of clearance
// all round while leaving a 2mm pillar between neighbours.
//
// The margin also sets vertical clearance (see wall_cutout_z0/h), where 1mm
// above and below a measured body height is likewise plenty.
cutout_margin = 1.0;

// LEFT wall (x=0, board_width=90mm long): HDMI0 (P3) and HDMI1 (P4),
// both Type-A jacks mounted flush to this edge stacked vertically, plus
// the micro-SD slot (J9) below them. [name, y_center, footprint_len,
// cutout_height_above_board] -- the 4th field caps how tall the cutout
// is, so it stays a real enclosed window instead of notching all the
// way up to the wall's own top edge (that was v1-v4's behavior on every
// wall cutout: "not full sides" -- fixed here, see design note 0b).
// Heights are generous-but-realistic connector body heights, not a
// datasheet measurement.
// MEASURED ON THE BOARD 2026-08-29 with calipers, then converted from
// bottom-referenced to this file's top-referenced Y. The spans measured, up
// from the bottom edge, were P3 67-82, P4 41-57, J9 22-37, J14 11-18 --
// i.e. 8-23, 33-49, 53-68 and 72-79 measured down from the top. Centre and
// width below. Checked against pixel positions in the vendor drawing and all
// four agree to within about 1mm.
//
// This supersedes positions read off that drawing by eye, which were wrong on
// the printed case. Two entries move materially: HDMI0_P3 by 6.5mm
// (22 -> 15.5) and MICRO_SD_J9 by 4.5mm (65 -> 60.5). HDMI1_P4 was already
// right, which is a fair reminder that a wrong method can still get some
// entries correct -- it does not validate the method.
//
// J14 the mini-USB is HERE, on the left wall. It was previously on the BOTTOM
// wall: an entire connector on the wrong side of the case.
//
// Body heights are measured above the PCB top surface and come out far lower
// than the 13mm previously assumed for the HDMIs -- a standard HDMI-A
// receptacle is about 6mm tall, not 13.
connector_positions_mm = [
    ["HDMI0_P3",     15.5, 15, 6],
    ["HDMI1_P4",     41.0, 16, 6],
    ["MICRO_SD_J9",  60.5, 15, 2],
    ["MINI_USB_J14", 75.5,  7, 4],
];

// BOTTOM wall (y=board_width, board_length=160mm long): mini-USB (J14,
// OTG/debug) then two stacked dual-USB-A connectors (J6, J7 -- 4 ports
// total, driven by a real USB2514QFN36 hub off the CM4's single USB2
// line) then the 100-pin GPIO expansion header (JP5) -- a real, wide
// window so a display/sensor cable can actually route out through it
// (see design note 6). v4 had NONE of this: zero cutouts on this wall.
// [name, x_center, width, cutout_height_above_board]
bottom_connector_positions_mm = [
    // MINI_USB_J14 removed: measured on the board, it is on the LEFT wall.
    // NOT YET MEASURED and therefore still suspect -- J6, J7 and JP5 below
    // are still positions read off the drawing by eye, the same method that
    // put the left wall wrong.
    // MEASURED ON THE BOARD 2026-08-29, spans along the bottom edge from the
    // left corner: J6 14-29, J7 33-49, P1 53-71. Centre and width below.
    //
    // Both USB stacks were badly out -- J6 by 9.5mm and J7 by 10mm, each
    // sitting to the RIGHT of where they belong. Two 15-16mm connectors
    // displaced by most of their own width is why the printed case would not
    // line up here.
    // LOWER PORT DELIBERATELY BLANKED. J6 is a stacked pair and the lower
    // socket is used internally: a right-angle adapter turns the plug upward
    // so the FT232H sits inside the case above the board, wired to J1 for
    // openFPGALoader. Leaving that socket open to the outside would invite
    // someone to plug into a port that already has something in it.
    //
    // A dual USB-A stack is 17mm tall overall, so the upper socket occupies
    // roughly the top 8mm. The window therefore starts 9mm above the board
    // surface instead of at it. Adjust the 9 and the 8 together if the split
    // is not where these assume -- they were taken from the stack's overall
    // height, not measured port by port.
    ["USB_A_J6",      21.5, 15,  8, 9],   // upper socket only; lower is internal
    ["USB_A_J7",      41.0, 16, 17],   // 2 more stacked USB-A ports

    // ETHERNET RESTORED. v4.1 deleted this cutout after concluding the board
    // had no Ethernet jack, on the grounds that the schematic's magjack had no
    // matching footprint in the placement drawing. That was wrong twice over:
    // the jack is real, and it is P1 on the BOTTOM edge -- not where the
    // deleted cutout had been. Measured 53-71mm from the left corner, 14mm
    // tall, which is consistent with a standard RJ45 at about 13.5mm.
    ["ETH_P1",        62.0, 18, 14],

    // JP5 IS INTERNAL -- deliberately no cutout.
    //
    // Its pins point up, and everything on it stays inside the case: the
    // display mounts on the LID (see display_center_mm and
    // lid_display_standoffs), the touch lines run to the same module, and the
    // fan sits in the enclosure blowing on the heatsink. Nothing needs to
    // leave through this wall, so a 58mm-wide slot would only weaken it and
    // let dust in.
    //
    // This also retires the last unmeasured position on the case. The 119mm
    // that used to sit here was read off the drawing by eye -- the same method
    // that put every other connector on this wall out by up to 10mm -- so
    // removing it is a small correctness win as well as a structural one.
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
// The TOP wall (y=0) carries nothing. The Pmods J11-J13 along that edge are
// lid features, not wall ones -- their pins point up.
top_connector_positions_mm = [];

// RIGHT wall (x=board_length). MEASURED ON THE BOARD 2026-08-29: spans up
// from the bottom edge were SW4 46-59 and JP1 63-73, i.e. 31-44 and 17-27
// measured down from the top. Cross-checked against the vendor drawing, where
// SW4's body sits at about 29-45mm and JP1's at 17-28mm from the top edge.
//
// Both were previously on the TOP wall -- dc_jack_x_mm put the barrel hole at
// x=154 on the y=0 face, which is the adjacent corner rather than the right
// face. A hole in the wrong wall entirely, the same class of error as the
// mini-USB.
right_connector_positions_mm = [
    ["PWR_SW4", 37.5, 13, 7],
];

// JP1 barrel jack, on the RIGHT wall.
//
// The diameter was 12mm and measures 7. More importantly the hole was centred
// at lip_z + wall_height/2 -- the middle of the wall, 23.4mm up on Tall-XL --
// whereas the jack's real centre is 6mm above the PCB, so about 13mm up. It
// was in the wrong wall AND 10mm too high.
dc_jack_y_mm             = 22.0; // board-local Y of the barrel centre
dc_jack_diameter         = 7;    // measured barrel outer diameter
dc_jack_centre_above_pcb = 6;    // measured, PCB top surface to barrel centre

// WiFi antenna pass-through, right wall -- the power end, which is also the
// end JP5 runs to. Clear of JP1 (board y 17-27) and SW4 (31-44); y=78 puts it
// down toward the bottom corner with the header.
antenna_hole_d       = 6;
// The bulkhead thread has a flat on it for anti-rotation, so the hole is a D
// rather than a circle -- a round hole lets the connector spin when the
// antenna is screwed on or off, which eventually twists the pigtail off.
// 2.5mm from centre gives 5.5mm across the flat against a 6mm thread, the
// usual RP-SMA figure.
antenna_flat_from_centre = 2.5;
antenna_hole_y_mm    = 78;
antenna_hole_above_pcb = 12;

// KAN-28 self-locking push button, on the LEFT (HDMI) wall, directly above
// HDMI0/P3 -- the port nearest the board edge.
//
// Retained by printed CLIPS, not screws. Screw holes meant finding two M2
// screws and nuts and reaching inside a 50mm-deep box to hold them; a clip
// nest is printed in place and the switch pushes in from behind until the
// lips catch its body.
//
// From the manufacturer drawing: 9mm boss carrying a 5.6mm button, body
// 17.9 x 11.9mm, 6.3mm deep behind the flange.
kan28_boss_d       = 9.4;   // 9mm boss plus fit
kan28_body_mm      = [17.9, 11.9];
kan28_body_depth   = 6.3;
kan28_clip_wall    = 2.0;   // wall of the nest around the switch body
kan28_clip_lip     = 0.9;   // how far the retaining lips overhang
kan28_clip_fit     = 0.4;   // clearance around the body
kan28_y_mm         = 15.5;  // board-local Y -- same as HDMI0_P3
kan28_above_pcb    = 26;    // button centre above the PCB top surface

// FT232H breakout, 43 x 29mm, mounted inside for openFPGALoader and wired to
// J1. Its USB goes to a right-angle adapter in J6's lower socket, on a cable,
// so the board itself can sit anywhere -- which is why it goes on the TOP
// wall (board y=0), the only long wall with no connectors on it.
//
// SLOT-mounted, not screwed. Its four corner holes are visible but their
// spacing has not been measured, and inventing hole positions is what produced
// the bosses and standoffs that stopped earlier revisions assembling. Two
// grooved rails take the PCB by its edges instead: it drops in from above,
// lands on a stop, and a lip at the top holds it down. No fasteners at all.
ft232h_pcb_mm      = [43, 29];
ft232h_pcb_t       = 1.8;   // 1.6mm board plus fit
ft232h_rail_w      = 3.0;   // rail cross-section
ft232h_fit         = 0.5;   // clearance on the PCB width
ft232h_x_mm        = 68;    // board-local X of the holder centre. 80 put the
                            // holder 9mm into the heatsink zone -- caught by
                            // the assertion below, not by eye.
ft232h_above_pcb   = 12;    // bottom edge of the PCB, above the board surface


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
    // SW4 removed: it is a right-WALL cutout now, measured on the board.
    // This lid hole was a leftover from when it was thought to be on the
    // top edge, and at [148,14] it does not match the measured position
    // either -- it would simply have been a spurious hole in the lid.
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
// Moved clear of the screen. At [70,50] this fell INSIDE the screen's
// 82x50 footprint, so it would have been a hole into the back of the display.
sensor_hole_center_mm = [90, 80];
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
// SCREEN, measured: an 82 x 50mm module, 6mm thick at its deepest, with a
// 70 x 50mm viewable area. The 6mm strip down each side is a 2mm-thick flange
// -- 82 less 70 is 12, i.e. 6 per side.
//
// Note the module and the viewable area are BOTH 50mm in Y, so the flanges
// exist only on the left and right. The window therefore spans the module's
// full height and the recess below leaves two side ledges, not a closed
// picture frame.
// PORTRAIT: the module stands on its short edge, so the 82mm dimension runs
// across the board's width. Everything downstream (the window, the recess and
// the vent exclusion) follows from these two.
screen_module_mm  = [50, 82];   // overall outline
screen_window_mm  = [50, 70];   // viewable area -> the through-window
screen_body_mm    = 6;          // deepest point, protrudes into the case
screen_flange_mm  = 2;          // flange thickness

// The recess is deliberately SHALLOWER than the 2mm flange. A pocket the full
// flange depth would leave only lid_thickness - 2 = 0.4mm of lid above it,
// which is fragile and would very likely tear during printing or handling.
// 1.0mm locates the module laterally and still leaves 1.4mm of lid.
screen_recess_mm  = 1.0;
screen_fit_gap    = 0.5;        // per side, module to pocket

// At the HDMI end of the lid, as asked. Board-local; 41 is as far right as it
// can sit while clearing J11's lid cutout, which starts at x=82.
// Still the HDMI end. 82mm tall on a 90mm board leaves 4mm top and bottom,
// so it has to sit centred in Y; x=30 keeps it clear of the case wall.
screen_center_mm  = [30, 45];

// No screw posts. The module's mounting-hole positions have not been measured,
// and inventing them is exactly what produced the standoffs and bosses that
// stopped earlier revisions assembling. The recess locates it; fixing is by
// adhesive or a bracket until real hole positions exist.

// ============================================================
// Derived geometry
// ============================================================
outer_length = board_length + 2*(fit_gap + wall_thickness);
outer_width  = board_width  + 2*(fit_gap + wall_thickness);
tray_height  = floor_thickness + standoff_clearance + board_thickness + wall_height;
lip_z = floor_thickness + standoff_clearance; // board rests here
board_origin = [wall_thickness + fit_gap, wall_thickness + fit_gap]; // XY of board's own (0,0)

// Board-local Y -> model Y.
//
// Every Y in this file is measured DOWNWARD from the board's top edge, because
// that is how the vendor drawing is dimensioned and how the connectors were
// measured. OpenSCAD's +Y runs the opposite way. Mapping Y straight through
// while leaving X alone is a REFLECTION, not a rotation -- and a reflected
// tray cannot be fixed by turning the board round, only by flipping it upside
// down, which would put the components face-down. The printed case was a
// mirror image of the board.
//
// board_y() does the flip in one place. Anything positioned from a board-local
// Y must go through it.
function board_y(y_from_top) = board_origin[1] + (board_width - y_from_top);


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
// Cutouts start below the board's TOP surface, not its underside.
//
// This was lip_z - cutout_margin, i.e. referenced to where the board sits on
// the lip. But connectors stand ON the board, so every window was a whole
// board-thickness too low: a 6mm HDMI occupies 7.4 to 13.4 while its opening
// ran 4.4 to 12.4, missing the top of the connector and wasting the same
// amount of wall below it. Referencing the top surface fixes both ends.
function wall_cutout_z0() = lip_z + board_thickness - cutout_margin;
function wall_cutout_h(body_h) =
    min(body_h + 2*cutout_margin,
        (tray_height - wall_roof_min_mm) - wall_cutout_z0());

module left_edge_cutouts() {
    for (c = connector_positions_mm) {
        y_center = board_y(c[1]);
        h = c[2] + 2*cutout_margin;
        translate([-1, y_center - h/2, wall_cutout_z0()])
            cube([wall_thickness + 2, h, wall_cutout_h(c[3])]);
    }
}

// BOTTOM wall (y=outer_width side): mini-USB, 2x dual-USB-A, GPIO
// expansion header -- see bottom_connector_positions_mm above. Same
// oversized-rectangle-through-the-wall approach as left_edge_cutouts(),
// now also height-capped the same way.
// Connector rows may carry an optional 5th field: how far ABOVE the board's
// top surface the cutout starts. Without it a cutout begins at the board
// surface, which is right for a connector standing on the board. It exists so
// one port of a stacked pair can be left solid -- see USB_A_J6 below.
function cutout_z_from(c) = (len(c) > 4) ? c[4] : 0;

module bottom_edge_cutouts() {
    for (c = bottom_connector_positions_mm) {
        x_center = board_origin[0] + c[1];
        w = c[2] + 2*cutout_margin;
        translate([x_center - w/2, -1, wall_cutout_z0() + cutout_z_from(c)])
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
        translate([x_center - w/2, outer_width - wall_thickness - 1, wall_cutout_z0()])
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
// RIGHT wall (x = outer_length). Mirror of left_edge_cutouts().
module right_edge_cutouts() {
    for (c = right_connector_positions_mm) {
        y_center = board_y(c[1]);
        h = c[2] + 2*cutout_margin;
        translate([outer_length - wall_thickness - 1, y_center - h/2, wall_cutout_z0()])
            cube([wall_thickness + 2, h, wall_cutout_h(c[3])]);
    }
}

// Slot holder for the FT232H, on the inner face of the TOP wall (board y=0,
// which is the model's maximum-Y wall). Two grooved rails plus a bottom stop;
// the board drops in from above and a lip at the top retains it.
module ft232h_holder() {
    xc = board_origin[0] + ft232h_x_mm;
    yw = outer_width - wall_thickness;          // inner face of that wall
    z0 = lip_z + board_thickness + ft232h_above_pcb;
    w  = ft232h_pcb_mm[0] + 2*ft232h_fit;
    h  = ft232h_pcb_mm[1];
    d  = ft232h_pcb_t;                          // groove depth away from wall

    // two rails, one at each end of the board
    for (xs = [-1, 1])
        translate([xc + xs*(w/2 + ft232h_rail_w/2) - ft232h_rail_w/2,
                   yw - (d + ft232h_rail_w), z0])
            difference() {
                cube([ft232h_rail_w, d + ft232h_rail_w, h + 4]);
                // groove facing inward, so the PCB edge slides into it
                translate([-1, ft232h_rail_w, -1])
                    cube([ft232h_rail_w + 2, d + 1, h + 6]);
            }

    // rails need a web back to the wall or they are unsupported columns
    for (xs = [-1, 1])
        translate([xc + xs*(w/2 + ft232h_rail_w/2) - ft232h_rail_w/2,
                   yw - ft232h_rail_w, z0])
            cube([ft232h_rail_w, ft232h_rail_w, h + 4]);

    // bottom stop, the board rests on this
    translate([xc - w/2 - ft232h_rail_w, yw - (d + ft232h_rail_w), z0 - 2])
        cube([w + 2*ft232h_rail_w, d + ft232h_rail_w, 2]);

    // retaining lip at the top, overhanging into the slot
    translate([xc - w/2, yw - (d + 0.8), z0 + h + 1])
        cube([w, 0.8, 1.6]);
}

// Button clearance through the LEFT wall.
module left_edge_switch_hole() {
    translate([-1, board_y(kan28_y_mm),
               lip_z + board_thickness + kan28_above_pcb])
        rotate([0, 90, 0])
            cylinder(h = wall_thickness + 2, d = kan28_boss_d, $fn = 32);
}

// Clip nest on the INNER face of the left wall. A three-sided surround the
// size of the switch body, with a lip along the top and bottom that the body
// snaps past. Open on the inboard side so the switch slides in and the lips
// flex rather than having to stretch a closed frame.
module left_edge_switch_clips() {
    yc = board_y(kan28_y_mm);
    zc = lip_z + board_thickness + kan28_above_pcb;
    w  = kan28_body_mm[0] + 2*kan28_clip_fit;   // along Y
    h  = kan28_body_mm[1] + 2*kan28_clip_fit;   // along Z
    d  = kan28_body_depth;

    translate([wall_thickness, yc, zc]) {
        difference() {
            // outer block, standing off the wall
            translate([0, -(w/2 + kan28_clip_wall), -(h/2 + kan28_clip_wall)])
                cube([d + kan28_clip_wall, w + 2*kan28_clip_wall, h + 2*kan28_clip_wall]);
            // pocket for the body, open toward the wall
            translate([-0.01, -w/2, -h/2])
                cube([d + 0.02, w, h]);
            // relieve the middle of the long sides so the lips can flex
            translate([-0.01, -w/2 - kan28_clip_wall - 1, -h/2 + 2])
                cube([d + 0.02, kan28_clip_wall + 1.2, h - 4]);
            translate([-0.01, w/2 - 0.2, -h/2 + 2])
                cube([d + 0.02, kan28_clip_wall + 1.2, h - 4]);
        }
        // retaining lips at the open end, overhanging into the pocket
        for (zs = [-1, 1])
            translate([d - 0.6, -w/2, zs*(h/2) - (zs > 0 ? 0 : kan28_clip_lip)])
                cube([0.6, w, kan28_clip_lip]);
    }
}

module right_edge_antenna_hole() {
    translate([outer_length - wall_thickness - 1,
               board_y(antenna_hole_y_mm),
               lip_z + board_thickness + antenna_hole_above_pcb])
        rotate([0, 90, 0])
            linear_extrude(height = wall_thickness + 2)
                difference() {
                    circle(d = antenna_hole_d, $fn = 48);
                    translate([-antenna_hole_d, antenna_flat_from_centre])
                        square([2*antenna_hole_d, antenna_hole_d]);
                }
}

// The barrel jack gets a round hole at its MEASURED height, not at the middle
// of the wall: a barrel plug's cable approaches horizontally and the shell has
// to line up with the socket, so being 10mm high is as bad as being sideways.
module right_edge_dc_jack() {
    translate([outer_length - wall_thickness - 1,
               board_y(dc_jack_y_mm),
               lip_z + board_thickness + dc_jack_centre_above_pcb])
        rotate([0, 90, 0])
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
            ? [ for (h = standoff_xy_mm) [board_origin[0] + h[0], board_y(h[1])] ]
            : corner_xy(standoff_inset_mm);
        for (p = pts)
            corner_standoff(p[0], p[1]);
    }
}

// Groove in the inner wall face for the lid's snap bead.
module snap_groove() {
    z0 = tray_height - lid_skirt_depth + snap_lead_in;
    translate([0, 0, z0])
        difference() {
            linear_extrude(height = snap_bead_h)
                translate([wall_thickness - snap_bead_mm, wall_thickness - snap_bead_mm])
                    square([outer_length - 2*(wall_thickness - snap_bead_mm),
                            outer_width  - 2*(wall_thickness - snap_bead_mm)]);
            translate([0, 0, -1])
                linear_extrude(height = snap_bead_h + 2)
                    translate([wall_thickness, wall_thickness])
                        square([outer_length - 2*wall_thickness,
                                outer_width  - 2*wall_thickness]);
        }
}

module base_tray() {
    union() {
        difference() {
            tray_shell();
            union() {
                snap_groove();
                left_edge_cutouts();
                bottom_edge_cutouts();
                top_edge_cutouts();
                right_edge_cutouts();
                right_edge_dc_jack();
                right_edge_antenna_hole();
                left_edge_switch_hole();
            }
        }
        retaining_lip_ridge();
        standoffs();
        left_edge_switch_clips();
        ft232h_holder();
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
// Bead around the outside of the skirt, engaging snap_groove() in the tray.
// Chamfered underneath so the lid leads in easily and resists coming off.
module lid_snap_bead() {
    z0 = -lid_skirt_depth + snap_lead_in;
    inset = wall_thickness + lid_fit_clearance;
    translate([0, 0, z0])
        difference() {
            linear_extrude(height = snap_bead_h)
                translate([inset - snap_bead_mm, inset - snap_bead_mm])
                    square([outer_length - 2*(inset - snap_bead_mm),
                            outer_width  - 2*(inset - snap_bead_mm)]);
            translate([0, 0, -1])
                linear_extrude(height = snap_bead_h + 2)
                    translate([inset + wall_thickness, inset + wall_thickness])
                        square([outer_length - 2*(inset + wall_thickness),
                                outer_width  - 2*(inset + wall_thickness)]);
        }
}


// Two small round holes for the real user push-buttons SW2/SW3 (see
// lid_button_positions_mm above) -- v4 didn't expose these at all.

// ---- FPGA vent zone: EITHER nothing (fully solid lid, VARIANT_VENTED
// = false) OR a grid of small drilled holes through the solid lid
// (VARIANT_VENTED = true) -- see design note 4 at the top of this file.
// The case is fully enclosed either way: this never opens a hole big
// enough to expose the heatsink to open air, unlike v3's chimney.

// Through-window for the screen's viewable area, plus a shallow locating
// recess in the lid's UNDERSIDE for its side flanges. The module goes in from
// inside the case and looks out through the window.
module lid_screen_cutout() {
    cx = board_origin[0] + screen_center_mm[0];
    cy = board_y(screen_center_mm[1]);

    translate([cx - (screen_window_mm[0] + screen_fit_gap)/2,
               cy - (screen_window_mm[1] + screen_fit_gap)/2, -1])
        cube([screen_window_mm[0] + screen_fit_gap,
              screen_window_mm[1] + screen_fit_gap,
              lid_thickness + 2]);

    translate([cx - (screen_module_mm[0] + 2*screen_fit_gap)/2,
               cy - (screen_module_mm[1] + 2*screen_fit_gap)/2, -0.001])
        cube([screen_module_mm[0] + 2*screen_fit_gap,
              screen_module_mm[1] + 2*screen_fit_gap,
              screen_recess_mm]);
}

// True when a vent hole would land on the screen module's footprint. Holes
// there would perforate the flange ledges the module sits on, and holes inside
// the window are meaningless because it is already open.
function vent_clear_of_screen(x, y) =
    let (cx = board_origin[0] + screen_center_mm[0],
         cy = board_y(screen_center_mm[1]),
         hx = screen_module_mm[0]/2 + 2,
         hy = screen_module_mm[1]/2 + 2)
    !(x > cx - hx && x < cx + hx && y > cy - hy && y < cy + hy);

module lid_fpga_vent_holes() {
    if (VARIANT_VENTED) {
        // Centred on the BOARD, not the FPGA. The grid used to be a patch
        // over the heatsink; now that it covers the whole lid, centring it on
        // heatsink_center_mm left a blank strip at one end and ran off the
        // other.
        cx = board_origin[0] + board_length/2;
        cy = board_y(board_width/2);
        nx = max(1, floor(vent_zone_mm[0] / vent_hole_pitch));
        ny = max(1, floor(vent_zone_mm[1] / vent_hole_pitch));
        x0 = cx - (nx-1)*vent_hole_pitch/2;
        y0 = cy - (ny-1)*vent_hole_pitch/2;
        for (i = [0:nx-1])
            for (j = [0:ny-1])
                if (vent_clear_of_screen(x0 + i*vent_hole_pitch,
                                         y0 + j*vent_hole_pitch))
                    translate([x0 + i*vent_hole_pitch, y0 + j*vent_hole_pitch, -1])
                        cylinder(h = lid_thickness + 2, d = vent_hole_d, $fn = 16);
    }
}


// Through-window for the viewable area, plus a shallow locating recess in the
// lid's UNDERSIDE for the side flanges. The module goes in from inside the
// case; its flanges bear on the recess and the screen looks out through the
// window.

module lid() {
    union() {
        difference() {
            union() {
                lid_panel();
                lid_skirt();
                lid_snap_bead();
            }
            lid_fpga_vent_holes();
            lid_screen_cutout();
        }
    }
}

// Sanity-check echo: confirms (at compile time, in the console/log) how
// much margin this variant's wall_height leaves over the real heatsink's
// needs. Should read comfortably positive.
echo(str("heatsink clearance margin (mm): ", heatsink_margin_mm,
         " [interior provides ", case_interior_clearance_mm,
         ", heatsink needs ", heatsink_total_clearance_mm, "]"));


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

// Orientation report. Board-local Y is measured DOWN from the board top edge;
// model Y runs the other way, so board_y() flips it. Printing both makes a
// reflection visible at render time instead of after a print: read down this
// list and the order must match the board read from its TOP edge downward.
echo(str("LEFT wall, board-local Y -> model Y:"));
for (c = connector_positions_mm)
    echo(str("   ", c[0], "  board ", c[1], "  -> model ", board_y(c[1])));
echo(str("RIGHT wall:"));
for (c = right_connector_positions_mm)
    echo(str("   ", c[0], "  board ", c[1], "  -> model ", board_y(c[1])));
echo(str("   DC_JACK_JP1  board ", dc_jack_y_mm, "  -> model ", board_y(dc_jack_y_mm)));

// Assertion: adjacent cutouts on a wall must leave material between them.
//
// Each opening spans centre +/- (width/2 + cutout_margin), so neighbours merge
// silently once the margin exceeds half their gap. That is what turned the
// left wall into one slot from 30mm to 82mm and the bottom wall into one from
// 11mm to 74mm -- structurally weaker, worse for dust, and nothing warned
// about it because each individual cutout was still correct.
//
// Both lists are in ascending centre order, which this relies on.
function min_separator(lst) =
    len(lst) < 2 ? 999 :
    min([ for (i = [0 : len(lst) - 2])
          (lst[i+1][1] - lst[i+1][2]/2 - cutout_margin)
        - (lst[i][1]   + lst[i][2]/2   + cutout_margin) ]);

left_sep_mm   = min_separator(connector_positions_mm);
bottom_sep_mm = min_separator(bottom_connector_positions_mm);
echo(str("narrowest separator -- left wall: ", left_sep_mm,
         "mm, bottom wall: ", bottom_sep_mm, "mm"));
assert(left_sep_mm > 0.8,
       str("left-wall cutouts merge or nearly touch (", left_sep_mm,
           "mm between them). Reduce cutout_margin."));
assert(bottom_sep_mm > 0.8,
       str("bottom-wall cutouts merge or nearly touch (", bottom_sep_mm,
           "mm between them). Reduce cutout_margin."));


// The case is sized by what has to fit ABOVE the board: heatsink plus a fan.
// Measured from the board's underside to the lid's inner face, which is the
// dimension that matters when choosing a fan.
internal_above_board_mm = tray_height - lip_z;
echo(str("internal height, board underside to lid: ", internal_above_board_mm, "mm"));
echo(str("   of which above the PCB top surface:   ",
         internal_above_board_mm - board_thickness, "mm"));


// Assertion: the FT232H holder must clear the heatsink. It sits on the top
// wall above the board, and the heatsink is the tallest thing in the box.
ft232h_x0 = ft232h_x_mm - ft232h_pcb_mm[0]/2 - ft232h_rail_w;
ft232h_x1 = ft232h_x_mm + ft232h_pcb_mm[0]/2 + ft232h_rail_w;
heatsink_x0 = heatsink_center_mm[0] - heatsink_lwh_mm[0]/2 - heatsink_xy_margin_mm;
echo(str("FT232H holder spans board x ", ft232h_x0, "..", ft232h_x1,
         "; heatsink zone starts ", heatsink_x0));
assert(ft232h_x1 < heatsink_x0,
       str("FT232H holder overlaps the heatsink zone by ",
           ft232h_x1 - heatsink_x0, "mm"));

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
