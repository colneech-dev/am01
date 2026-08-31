// QMTECH XC7K325T Dev Board -- two-part case (base tray + lid)
//
// v4.2 -- FIT-CHECK CORRECTIONS, 2026-08-30. The v4.1 tray was printed and
// tried with the real board, switch, screen and adapters in hand. Twelve
// things came back. They are marked "FIT-CHECK item N" at each site; the
// three that changed the case's shape rather than a dimension are:
//
//   item 5  9mm of extra room at each LONG wall. The FT232H holder and the
//           switch nest both stand off their wall directly over where the
//           board has to drop in, and with a 1.2mm gap the board fouled them.
//           This is what made the tray unassemblable, and fixing it also
//           retires the USB cap (item 11) and unblocks item 9.
//   item 4  The retaining lip ran as a band floating 4.4mm above the floor,
//           so its whole underside printed as an unsupported overhang. It is
//           a plinth from the floor now. Its reach is per-axis, because after
//           item 5 the long walls stand 10.2mm off the board and a single
//           lip_ledge left those two edges carrying nothing.
//   item 1  6mm lid, matching the screen module's own thickness, with the
//           headroom added back in item 12 so nothing is lost.
//
// Nothing here was found by re-reading the model. Every one of them came from
// putting the printed part on the bench with the hardware -- which is the
// same lesson as the v4.1 mirror bug, where every check compared the model
// against itself and none against the board.
//
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
VARIANT_WALL_HEIGHT = 24;   // SEALED variant: fully solid lid, no venting
VARIANT_VENTED       = false;  // SEALED variant: fully solid lid, no venting

// Which display the LID is cut for. The tray is identical either way -- only
// the lid's window, pocket and vent-exclusion change.
//   "ili9341"  the 82x50 module wired to JP5
//   "cyd"      an ESP32 "Cheap Yellow Display": 91x50, carries its own ESP32,
//              and talks to the miner over the network or USB rather than JP5,
//              so it needs no JP5 wiring at all
VARIANT_SCREEN       = "ili9341";  // SEALED variant: fully solid lid, no venting

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
fit_gap        = 1.2;    // extra clearance around the board footprint

// FIT-CHECK 2026-08-30, item 5: 9mm of extra internal room at each LONG wall
// (the two 160mm walls, y=0 and y=90). The board stays centred; the case grows
// 18mm in Y.
//
// This is what makes three other things work:
//   - the FT232H stands 5.8mm off the top wall and the KAN-28 switch nest
//     6.3mm, both directly over where the board has to drop in. With a 1.2mm
//     gap the board fouled them on the way down (items 9 and the reason the
//     tray would not assemble);
//   - the right-angle USB adapter projects 11mm past J6's connector face, and
//     now lives inside the case instead of needing a bump over the wall
//     (item 11 retires the USB cap);
//   - a 10.2mm gap between the connector faces and the wall means plugs on the
//     bottom wall reach their sockets THROUGH the wall opening. The openings
//     are sized to the connector body plus margin, which is wider than a USB-A
//     or RJ45 overmould, so they pass -- but that is now load-bearing, and a
//     plug with an unusually fat boot will not seat.
extra_side_gap_mm = 9.0;
fit_gap_x      = fit_gap;                      // short walls, unchanged
fit_gap_y      = fit_gap + extra_side_gap_mm;  // long walls
// The lip must reach past the board's edge by more than fit_gap, or there
// is nothing under the board to carry it. At fit_gap 1.2 a 1.5mm ledge
// would leave only 0.3mm of bearing surface; 3.0 leaves 1.8mm all round.
lip_ledge      = 3.0;    // how far the lip reaches in from the inner wall face
// FIT-CHECK item 4: the lip used to be a 2mm-thick band floating at
// lip_z - lip_thickness with nothing beneath it, so its underside printed as a
// full-perimeter overhang in mid-air. It now runs from the floor up to lip_z --
// a plinth, not a ledge -- so every layer is supported by the one below.
// lip_thickness is what that floating band's Z height used to be; kept only so
// the change is legible in a diff.
lip_thickness  = 2.0;    // HISTORICAL -- no longer used, see retaining_lip_ridge()

// The lip has to reach across the gap between the wall and the board edge
// before it reaches UNDER the board, and after item 5 that gap is 10.2mm on
// the long walls against 1.2mm on the short ones. One lip_ledge for both axes
// would leave the two long edges of the board completely unsupported -- the
// lip would stop 7mm short of the board and only the standoffs would carry it.
lip_bearing_target = 1.8;               // how far the lip reaches under the board
lip_ledge_x = lip_ledge;                            // short walls
lip_ledge_y = fit_gap_y + lip_bearing_target;       // long walls, spans the gap

// ---- Tray shell ----
wall_thickness  = 2.4;
floor_thickness = 2.4;
standoff_clearance = 5.0;   // gap under the board for bottom-side components/solder.
                            // FIT-CHECK item 4 asked for 4.0, revised to 5.0
                            // on the bench. Was 3.0.
                            // extra_headroom_mm below adds this back to the
                            // wall height, so the room above the board does
                            // not shrink when the board is lifted.

// Case interior height, uniform everywhere (fully enclosed -- see design
// note 3 above). Set directly by VARIANT_WALL_HEIGHT; also cross-checked
// below against the real heatsink dimensions so you can see the margin
// (or shortfall) rather than trust a bare constant.
// FIT-CHECK item 1: the lid's main panel matches the screen module's own
// 6mm thickness, so the module sits inside the panel rather than hanging below
// it. That also lets the flange recess go to its full 2mm (see
// screen_recess_mm) instead of the 1.0mm a 2.4mm lid could afford.
lid_thickness = 6.0;

// FIT-CHECK item 12: keep the headroom above the board that VARIANT_WALL_HEIGHT
// names, then add back what the other changes consume, plus clearance for the
// fan screws. Written as a sum rather than a new constant so each term stays
// attributable -- and so the sealed/vented variants, whose VARIANT_WALL_HEIGHT
// render_cases.sh rewrites to 24, get the same compensation automatically.
extra_headroom_mm = (standoff_clearance - 3.0)   // item 4, taller standoffs
                  + (lid_thickness - 2.4)        // item 1, thicker lid
                  + 2.0;                         // item 12, fan screw heads
wall_height = VARIANT_WALL_HEIGHT + extra_headroom_mm;

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
// What this variant provides, board TOP surface to the lid's underside. The
// lid used to be ADDED here, which is backwards -- it is solid material above
// the interior, not part of it. Harmless while the lid was 2.4mm; with a 6mm
// lid it would have overstated the clearance by the same 6mm.
case_interior_clearance_mm  = wall_height;
heatsink_margin_mm = case_interior_clearance_mm - heatsink_total_clearance_mm; // sanity check;
                      // should be comfortably positive -- echoed at the bottom of this file

// Footprint the vent-hole grid (if VARIANT_VENTED) is centered on --
// oversized around the heatsink body the same way the old chimney was.
// Venting is now the WHOLE lid, not a patch over the FPGA. A sealed box
// around a part that already ran too hot to touch was the wrong default; the
// grid is cheap to print and costs nothing but a little rigidity.
// Measured from the CASE, with a border wide enough to clear the lid's skirt.
// It used to be the BOARD footprint centred on the lid, which put the outermost
// hole centres 3.6mm from the lid edge -- inside the skirt band (2.7 to 5.1mm),
// so the vent grid was drilling through the skirt it depends on. Item 5's extra
// 18mm of width would have left an unvented band there as well.
vent_border_mm = 8;
// vent_zone_mm itself is assigned in the Derived geometry section below,
// because it needs outer_length/outer_width and OpenSCAD resolves file-scope
// variables IN ORDER -- assigned here it silently evaluated to undef and the
// whole vent grid disappeared from the lid without an error.
// HEXAGONS, hex-packed. Circles in a square grid gave about 14% open area:
// a circle leaves four wasted corners against its neighbours, and square
// packing wastes more again. A hexagon tiles the plane completely, so the only
// material left is the web itself.
//
// Bridging is not a consideration -- the lid prints flat, so every hole is
// just a perimeter in each layer whatever its shape. What limits this is web
// strength and print time: below about 1.2mm the webs get fragile, and many
// small holes means a lot of perimeters.
//
// vent_hole_d is ACROSS FLATS for a hex, or the diameter for a circle. The
// pitch is centre to centre along a row; rows are staggered by half a pitch
// and spaced pitch*sin(60), which is what makes it hex-packed rather than
// square.
vent_shape        = "hex";   // "hex" or "circle"
vent_hole_d       = 3.4;     // across flats
vent_hole_pitch   = 4.6;     // centre to centre -> 1.2mm webs

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
// FIT-CHECK item 2: 0.6mm of interference would not go on -- the printed lid
// did not clip in at all. 0.35 is still a positive detent at this wall
// thickness. If it is STILL tight, the next knob is lid_fit_clearance (0.3 per
// side): the bead and the skirt are in series, and a tight skirt reads exactly
// the same way from outside.
snap_bead_mm   = 0.35;  // radial interference
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
// FIT-CHECK items 7 and 10: the pillars between adjacent windows were 2mm and
// are wanted at 3mm+. Every adjacent pair on this board is 4mm apart (J6/J7,
// J7/P1, P4/J9), so the pillar is exactly 4 - 2*cutout_margin: 0.5 gives 3.0mm
// on all of them at once. It also tightens the vertical clearance to 0.5mm
// above and below each connector body, which is still a real clearance.
cutout_margin = 0.5;

// ---- Removable USB cap: RETIRED (fit-check item 11) -----------------
// The cap existed because the right-angle adapter in J6 projects 11mm past the
// connector face and no flat wall could accommodate it. Item 5 puts 10.2mm of
// room between the board edge and the wall, so the adapter now sits INSIDE the
// case and the wall needs no bump at all. J6 goes back to a plain window over
// its lower socket -- see USB_A_J6 below and item 6.

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
    // FIT-CHECK item 8: 11mm wide x 6mm high, asked for so the plug's
    // overmould passes rather than just the 7 x 4mm receptacle. With
    // cutout_margin 0.5 that is a 10 x 5 body entry.
    //
    // This is the one pillar on the case narrower than 3mm: J9 ends at 68.5
    // and this window starts at 70.0, so 1.5mm. It is left centred on the
    // measured connector rather than nudged along to widen the pillar -- a
    // window that does not line up with its plug is the worse failure.
    // FIT-CHECK 2026-08-31: 11mm wide x 8mm high at the opening (was 11 x 6).
    // With cutout_margin 0.5 that is a 10 x 7 body entry.
    ["MINI_USB_J14", 75.5, 10, 7],
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
    // FIT-CHECK item 6: only J6's LOWER socket gets a window. The TOP socket
    // carries the internal cable to the FT232H/JTAG adapter, so opening it
    // would just be a hole. Measured span along the bottom edge is 14-29mm,
    // centre 21.5, width 15.
    //
    // One port of the stack is 8mm of body, which with cutout_margin 0.5 gives
    // the 9mm opening asked for (it was ~24mm, the full stack plus the cap
    // allowance). The cutout starts at the board's top surface, so the solid
    // wall left above it is what blanks the upper socket.
    ["USB_A_J6",       21.5, 15, 8],
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
// FIT-CHECK item 3a: 6mm would not pass the bulkhead thread. An RP-SMA
// bulkhead is a 1/4-36 or M6.5 thread, i.e. about 6.35mm over the crest, so a
// 6mm hole was under-size before the D-flat took anything off it.
antenna_hole_d       = 6.8;
// The bulkhead thread has a flat on it for anti-rotation, so the hole is a D
// rather than a circle -- a round hole lets the connector spin when the
// antenna is screwed on or off, which eventually twists the pigtail off.
// The flat has to clear the thread's own flat, which has not been measured on
// this connector. 3.1mm from centre gives 6.2mm across the flat -- generous
// enough that it cannot be what blocks the thread, while still stopping the
// body turning more than a few degrees.
antenna_flat_from_centre = 3.1;

// FIT-CHECK item 3b: moved 15mm along the wall, away from the bottom edge.
// Board-local Y 78 -> 63. Height unchanged (antenna_hole_above_pcb below).
//
// Stays BOARD-relative, and the distinction matters. Measured on the printed
// case the hole sat 15.6mm from the bottom outer edge; the ask was to double
// that to 30. But item 5's extra 9mm at that wall carries everything
// board-referenced along with it, so the same hole is already at 24.6mm before
// any move is applied -- and the 15mm move then lands it at 39.6mm from the
// edge, not 30.
//
// This was first implemented as a fixed 30mm from the case's outer face, which
// would have SWALLOWED the 9mm instead of adding to it. "Lands in the same
// place" means the same place relative to the board -- the pigtail runs to a
// board-mounted connector -- not the same distance from a wall that moves.
// Board-local is therefore the correct reference, and the case growing again
// will carry the hole with the board exactly as it did here.
antenna_hole_y_mm    = 63;
antenna_hole_above_pcb = 12;

// KAN-28 self-locking push button, on the TOP wall (board y=0) -- the same
// wall as the FT232H.
//
// FIT-CHECK item 9: it was on the LEFT (HDMI) wall directly above HDMI0/P3,
// where its clip nest stands 6.3mm proud of a wall only 1.2mm from the board
// edge. The board fouled it on the way in and the tray would not assemble.
// The top wall carries no connectors at all, and after item 5 it has 10.2mm of
// clear space in front of it -- enough for the 6.3mm nest with 3.9mm to spare,
// entirely outside the board footprint.
//
// x=30 is board-local, at the HDMI end of that wall and well clear of the
// FT232H, which spans x 96.5-139.5.
//
// Retained by printed CLIPS, not screws. Screw holes meant finding two M2
// screws and nuts and reaching inside a 50mm-deep box to hold them; a clip
// nest is printed in place and the switch pushes in from behind until the
// lips catch its body.
//
// From the manufacturer drawing: 9mm boss carrying a 5.6mm button, body
// 17.9 x 11.9mm, 6.3mm deep behind the flange.
//
// MEASURED ON THE PART 2026-08-31: 7mm thick (behind the flange) and 12.5mm
// high. The drawing's 6.3 and 11.9 were both under, which on a snap fit is
// the direction that binds -- the nest would have had to spring 0.7mm wider
// than designed to let the body in at all.
kan28_boss_d       = 9.4;   // 9mm boss plus fit
kan28_body_mm      = [17.9, 12.5];
kan28_body_depth   = 7.0;
kan28_clip_wall    = 2.0;   // wall of the nest around the switch body
kan28_clip_lip     = 0.9;   // how far the retaining lips overhang
kan28_clip_fit     = 0.4;   // clearance around the body
// Width of each of the two TOP arms, at the ends of the body's span.
//
// The top arm is the one that has to spring out of the way as the switch is
// pushed in; the bottom is just a ledge it lands on. As one 17.9mm-wide plate
// the top arm was stiff enough that seating the switch meant levering a
// printed part -- which is how printed clips get broken off rather than bent.
// Two short arms at the ends flex far more readily for the same wall
// thickness, and leave the middle of the top edge open.
kan28_clip_end_w   = 5.0;
kan28_x_mm         = 30;    // board-local X along the TOP wall
kan28_above_pcb    = 26;    // button centre above the PCB top surface

// FT232H breakout, 43 x 29mm, mounted inside for openFPGALoader and wired to
// J1. Its USB goes to a right-angle adapter in J6's lower socket, on a cable,
// so the board itself can sit anywhere -- which is why it goes on the TOP
// wall (board y=0), the only long wall with no connectors on it.
//
// STALE COMMENT REMOVED. This paragraph described slot rails and "no fasteners
// at all" long after the geometry had been changed back to four screw posts,
// so the file's own documentation contradicted what it actually built. The
// posts are what is built, on the hole spacing confirmed below.
ft232h_pcb_mm      = [43, 29];
ft232h_pcb_t       = 1.8;   // 1.6mm board plus fit

// CONFIRMED ON THE HARDWARE, 2026-08-30. These were derived as a 3mm inset
// from each edge and carried an "ASSUMED, NOT MEASURED" warning through
// several revisions -- they were the last number on the whole case that had
// not been checked against a real part. The printed tray was offered up to the
// actual FT232H breakout and the posts line up, so 37 x 23 is right and is
// deliberately UNCHANGED here.
//
// Worth keeping the history: the inset guess happened to be correct, which is
// luck rather than method. It is measured now either way.
ft232h_hole_pitch  = [37, 23];
ft232h_post_od     = 5.0;
ft232h_post_ht     = 4.0;   // lifts the board off the wall for its solder side
ft232h_post_pilot  = 2.4;   // M2.5 self-tap

// Between the board's own standoffs at x=80 and x=156.2, over toward the
// power end. It sits against the TOP wall (board y=0) while the heatsink is at
// y=45, so the two never share space even where their X ranges overlap.
ft232h_x_mm        = 118;
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
// ---- ILI9341, the JP5-wired module -----------------------------------
ili_module_mm     = [50, 82];   // overall outline
ili_window_mm     = [50, 70];   // viewable area -> the through-window
ili_recess_mm     = 2.0;        // = flange thickness; module sits flush
ili_center_mm     = [30, 45];   // board-local centre
ili_window_off_mm = [0, 0];     // display IS centred on this module

// ---- CYD (ESP32 Cheap Yellow Display), measured 2026-08-31 -----------
// 91 x 50 overall, 6mm thick: a 2mm PCB with the display standing 4mm proud
// of it. Same orientation as the ILI9341 -- the 91mm runs across the board's
// width (Y). It fits: the lid is 115.2mm in Y, so 91 leaves 12mm either side,
// and at 50mm in X it stays clear of the J11/J12/J13 lid cutouts at x>=90.
//
// The display is NOT centred on its PCB. There is 7mm of board beyond the
// glass at one end and 9mm at the other, so the window is offset 1mm from the
// module centre -- get this wrong and the bezel is visibly lopsided.
//   91 - 7 - 9 = 75mm of glass, spanning the full 50mm width.
cyd_module_mm     = [50, 91];
cyd_window_mm     = [50, 75];
cyd_margin_lo_mm  = 7;          // low-Y end
cyd_margin_hi_mm  = 9;          // high-Y end -- carries the light sensor
// (9 - 7)/2, pushing the window toward the 7mm end.
cyd_window_off_mm = [0, -(cyd_margin_hi_mm - cyd_margin_lo_mm)/2];
// The PCB is what the ledges bear on, so the pocket is the PCB thickness and
// the display fills the remaining 4mm of the 6mm lid -- landing flush.
cyd_pcb_mm        = 2.0;
cyd_recess_mm     = cyd_pcb_mm;
cyd_center_mm     = [30, 45];

// LIGHT SENSOR. On the 9mm side, 4mm out from the glass, and standing 3mm
// above the PCB. Two problems, one hole:
//   - it needs light, and a solid ledge would blind it
//   - at 3mm it fouls the 4mm-thick ledge it sits under
// A through-slot in the ledge solves both.
//
// A SLOT, not a hole, because its position ACROSS the width was not measured.
// A slot spanning most of the width catches it wherever it sits; narrow this
// to a neat hole once the position is known.
cyd_ldr_from_glass_mm = 4;
cyd_ldr_slot_mm       = [26, 5];   // X extent, Y extent

// ---- selected by VARIANT_SCREEN --------------------------------------
is_cyd            = (VARIANT_SCREEN == "cyd");
screen_module_mm  = is_cyd ? cyd_module_mm     : ili_module_mm;
screen_window_mm  = is_cyd ? cyd_window_mm     : ili_window_mm;
screen_window_off_mm = is_cyd ? cyd_window_off_mm : ili_window_off_mm;
screen_ldr_slot_mm   = is_cyd ? cyd_ldr_slot_mm  : [0, 0];
screen_ldr_from_glass_mm = is_cyd ? cyd_ldr_from_glass_mm : 0;
screen_body_mm    = 6;          // deepest point, protrudes into the case
screen_flange_mm  = 2;          // flange thickness

// The recess is the FULL flange thickness now. It was held at 1.0mm because a
// 2mm pocket in a 2.4mm lid left 0.4mm of skin above it, which would have torn.
// With item 1's 6mm lid there is 4mm above a full-depth pocket, so the module
// can sit flush instead of standing 1mm proud of the lid.
screen_recess_mm  = is_cyd ? cyd_recess_mm : ili_recess_mm;

// PER SIDE, module to pocket. A VECTOR because the two axes needed different
// answers: the printed lid would not take the module in Y at 0.5, which is the
// axis the module is measured "tall" in (82mm on the ILI9341) and so the one
// where tolerance stacks up. X was fine. Raised to 1.0 in Y; the window uses
// half of it, since a window gap only has to clear the glass, not swallow the
// whole module.
screen_fit_gap_mm = [0.5, 1.0];

// At the HDMI end of the lid, as asked. Board-local; 41 is as far right as it
// can sit while clearing J11's lid cutout, which starts at x=82.
// Still the HDMI end. 82mm tall on a 90mm board leaves 4mm top and bottom,
// so it has to sit centred in Y; x=30 keeps it clear of the case wall.
screen_center_mm  = is_cyd ? cyd_center_mm : ili_center_mm;

// No screw posts. The module's mounting-hole positions have not been measured,
// and inventing them is exactly what produced the standoffs and bosses that
// stopped earlier revisions assembling. The recess locates it; fixing is by
// adhesive or a bracket until real hole positions exist.

// ============================================================
// Derived geometry
// ============================================================
outer_length = board_length + 2*(fit_gap_x + wall_thickness);
outer_width  = board_width  + 2*(fit_gap_y + wall_thickness);
tray_height  = floor_thickness + standoff_clearance + board_thickness + wall_height;
lip_z = floor_thickness + standoff_clearance; // board rests here
board_origin = [wall_thickness + fit_gap_x, wall_thickness + fit_gap_y]; // XY of board's own (0,0)

// See vent_border_mm above for why this is assigned here and not there.
vent_zone_mm = [outer_length - 2*vent_border_mm,
                outer_width  - 2*vent_border_mm];

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
    fuse_eps = 0.05;
    h = lip_z - floor_thickness + fuse_eps;
    translate([0, 0, floor_thickness - fuse_eps])
    difference() {
        linear_extrude(height = h)
            square([outer_length, outer_width]);
        translate([wall_thickness + lip_ledge_x, wall_thickness + lip_ledge_y, -1])
            linear_extrude(height = h + 2)
                square([outer_length - 2*(wall_thickness + lip_ledge_x),
                        outer_width  - 2*(wall_thickness + lip_ledge_y)]);
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
// FIT-CHECK 2026-08-31: every wall opening sits 2mm too low on the printed
// part, so the bottom of each window overlaps the board's own edge instead of
// starting above it.
//
// The z0 below was lip_z + board_thickness - cutout_margin, i.e. it began
// cutout_margin BELOW the board's top surface. That allowance made sense as
// vertical clearance for a connector body, but the board is 2mm thick and its
// edge occupies exactly that space -- so the margin ate into the wall that
// should be solid alongside the PCB, and every window ended up low.
//
// Lifted by a full board thickness and the margin removed from the bottom
// edge, which leaves at least board_thickness of unbroken wall below every
// opening -- the "2mm bit around the bottom" this was missing.
cutout_lift_mm = 2.0;
function wall_cutout_z0() = lip_z + board_thickness + cutout_lift_mm;
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

// Four standoffs for the FT232H, on the inner face of the TOP wall (board
// y=0, the model's maximum-Y wall). Posts rather than the slot rails that were
// here before: asked for explicitly, and they hold the board positively
// instead of relying on edge friction.
module ft232h_posts() {
    xc = board_origin[0] + ft232h_x_mm;
    yw = outer_width - wall_thickness;
    zc = lip_z + board_thickness + ft232h_above_pcb + ft232h_pcb_mm[1]/2;
    for (dx = [-1, 1], dz = [-1, 1])
        translate([xc + dx*ft232h_hole_pitch[0]/2,
                   yw,
                   zc + dz*ft232h_hole_pitch[1]/2])
            rotate([90, 0, 0])
                difference() {
                    cylinder(h = ft232h_post_ht, d = ft232h_post_od, $fn = 24);
                    translate([0, 0, -1])
                        cylinder(h = ft232h_post_ht + 2, d = ft232h_post_pilot, $fn = 16);
                }
}

// Button clearance through the TOP wall (y = outer_width).
module top_edge_switch_hole() {
    translate([board_origin[0] + kan28_x_mm,
               outer_width - wall_thickness - 1,
               lip_z + board_thickness + kan28_above_pcb])
        rotate([-90, 0, 0])
            cylinder(h = wall_thickness + 2, d = kan28_boss_d, $fn = 32);
}

// Two L-shaped snap arms on the inner face of the top wall -- not a box.
//
// A closed surround meant threading the switch into a pocket; two arms let it
// go straight in and click. Each arm is an L in section: a post standing off
// the wall by the switch's body depth, with a hook at its end that overhangs
// the body and holds it against the wall.
//
// THE TOP ARM IS SPLIT IN TWO, 2026-08-31.
//
// Still one arm below and one above, as before -- but the top is now two
// short arms at the ends of the span rather than a single plate across the
// full 17.9mm body width. The top arm is the only one that has to deflect
// (the bottom is a ledge the body lands on and never moves), and at full
// width it was stiff enough that seating the switch meant levering a printed
// part rather than springing it.
//
// The sides stay completely open for the terminals and wiring, and the middle
// of the top edge is now open too.
module kan28_clip_arm(x0, arm_w, zs, d, yi, z0) {
    translate([x0, yi - d, z0]) {
        // upright of the L: stands off the wall, spanning the body depth
        translate([0, 0, (zs > 0) ? 0 : -kan28_clip_wall])
            cube([arm_w, d, kan28_clip_wall]);
        // foot of the L, at the far end from the wall: hooks back over the
        // switch body and holds it against the wall's inner face
        translate([0, 0, (zs > 0) ? -kan28_clip_lip : -kan28_clip_wall])
            cube([arm_w, kan28_clip_lip, kan28_clip_lip + kan28_clip_wall]);
    }
}

module top_edge_switch_clips() {
    xc = board_origin[0] + kan28_x_mm;
    zc = lip_z + board_thickness + kan28_above_pcb;
    w  = kan28_body_mm[0] + 2*kan28_clip_fit;   // along X, the body's span
    h  = kan28_body_mm[1] + 2*kan28_clip_fit;   // along Z, the gap between arms
    d  = kan28_body_depth;
    yi = outer_width - wall_thickness;          // inner face of the top wall
    ew = min(kan28_clip_end_w, w/2);            // each top arm, clamped so the
                                                // two can never meet in the middle

    // BOTTOM: one arm across the full width. It only ever bears the body's
    // weight, so there is nothing to gain by splitting it and a continuous
    // ledge locates the switch better.
    kan28_clip_arm(xc - w/2, w, -1, d, yi, zc - h/2);

    // TOP: two short arms, one at each end of the span.
    kan28_clip_arm(xc - w/2,      ew, +1, d, yi, zc + h/2);
    kan28_clip_arm(xc + w/2 - ew, ew, +1, d, yi, zc + h/2);
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

// How tall the two INTERNAL wall-mounted assemblies stand above the board's top
// surface, and whether this variant's walls are tall enough to contain them.
//
// Found by measuring the rendered STLs, not by reading the model: the sealed
// and vented trays came out 48.9mm tall against a 39.0mm wall, because the
// FT232H posts and the switch clips were being built straight through the top
// of a wall too short to hold them. The tall-xl variant has always had room, so
// nothing looked wrong there -- exactly the shape of bug that only a number
// measured off the OUTPUT catches.
//
// These are omitted rather than asserted against, so the short variants still
// render. What must never happen is omitting them SILENTLY, hence the echo.
board_top_z          = lip_z + board_thickness;
ft232h_stack_mm      = ft232h_above_pcb + ft232h_hole_pitch[1]/2
                       + ft232h_pcb_mm[1]/2 + ft232h_post_od/2;
// The + kan28_clip_wall term is the TOP arm, which still sits above the body:
// splitting it into two end arms changed its width, not its height. The body
// grew to 12.5mm on 2026-08-31, so this went 34.35 -> 34.65mm.
kan28_stack_mm       = kan28_above_pcb + kan28_body_mm[1]/2 + kan28_clip_fit
                       + kan28_clip_wall;
ft232h_fits          = ft232h_stack_mm <= wall_height;
kan28_fits           = kan28_stack_mm  <= wall_height;
echo(str("SCREEN [", VARIANT_SCREEN, "] module ", screen_module_mm,
         " window ", screen_window_mm,
         " -> board-local Y ", screen_center_mm[1] - screen_module_mm[1]/2,
         "..", screen_center_mm[1] + screen_module_mm[1]/2,
         " (lid spans ", -board_origin[1], "..", outer_width - board_origin[1], ")"));
echo(str("internal mounts vs wall_height ", wall_height, ": FT232H needs ",
         ft232h_stack_mm, " (", ft232h_fits ? "fits" : "OMITTED",
         "), switch needs ", kan28_stack_mm, " (", kan28_fits ? "fits" : "OMITTED", ")"));

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
                if (kan28_fits) top_edge_switch_hole();
            }
        }
        retaining_lip_ridge();
        standoffs();
        if (kan28_fits) top_edge_switch_clips();
        if (ft232h_fits) ft232h_posts();
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
    // Window centre. Offset from the module centre for a display that is not
    // centred on its own PCB -- the CYD is not, 7mm of board one end and 9mm
    // the other.
    wx = cx + screen_window_off_mm[0];
    wy = cy + screen_window_off_mm[1];

    // Through-window for the glass. Half the pocket clearance: this only has
    // to clear the display, not admit the whole module.
    translate([wx - (screen_window_mm[0] + screen_fit_gap_mm[0])/2,
               wy - (screen_window_mm[1] + screen_fit_gap_mm[1])/2, -1])
        cube([screen_window_mm[0] + screen_fit_gap_mm[0],
              screen_window_mm[1] + screen_fit_gap_mm[1],
              lid_thickness + 2]);

    // Pocket the module body drops into from inside, leaving the ledges it
    // bears on.
    translate([cx - (screen_module_mm[0] + 2*screen_fit_gap_mm[0])/2,
               cy - (screen_module_mm[1] + 2*screen_fit_gap_mm[1])/2, -0.001])
        cube([screen_module_mm[0] + 2*screen_fit_gap_mm[0],
              screen_module_mm[1] + 2*screen_fit_gap_mm[1],
              screen_recess_mm]);

    // Light-sensor slot, CYD only. Goes all the way through the ledge, which
    // is doing two jobs: the sensor needs light, and at 3mm tall it would
    // otherwise foul the 4mm ledge above it.
    if (screen_ldr_slot_mm[0] > 0) {
        ldr_cy = wy + screen_window_mm[1]/2 + screen_ldr_from_glass_mm;
        translate([wx - screen_ldr_slot_mm[0]/2,
                   ldr_cy - screen_ldr_slot_mm[1]/2, -1])
            cube([screen_ldr_slot_mm[0], screen_ldr_slot_mm[1],
                  lid_thickness + 2]);
    }
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
        cx = board_origin[0] + board_length/2;
        cy = board_y(board_width/2);
        row_dy = vent_hole_pitch * sin(60);
        nx = max(1, floor(vent_zone_mm[0] / vent_hole_pitch));
        ny = max(1, floor(vent_zone_mm[1] / row_dy));
        x0 = cx - (nx-1)*vent_hole_pitch/2;
        y0 = cy - (ny-1)*row_dy/2;
        // circle(d=..., $fn=6) is measured across CORNERS, so scale up to get
        // the requested across-flats dimension.
        hex_d = vent_hole_d * 2 / sqrt(3);
        for (j = [0:ny-1]) {
            // stagger alternate rows by half a pitch -- this is what makes the
            // packing hexagonal rather than square
            xoff = (j % 2 == 0) ? 0 : vent_hole_pitch/2;
            for (i = [0:nx-1]) {
                px = x0 + i*vent_hole_pitch + xoff;
                py = y0 + j*row_dy;
                if (vent_clear_of_screen(px, py))
                    translate([px, py, -1])
                        linear_extrude(height = lid_thickness + 2)
                            rotate([0, 0, 30])
                                circle(d = (vent_shape == "hex") ? hex_d : vent_hole_d,
                                       $fn = (vent_shape == "hex") ? 6 : 16);
            }
        }
    }
}

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
echo(str("   ANTENNA      board ", antenna_hole_y_mm,
         "  -> model ", board_y(antenna_hole_y_mm),
         " (i.e. that far from the case's bottom outer face)"));
echo(str("TOP wall: KAN-28 switch at board x ", kan28_x_mm,
         ", FT232H at board x ", ft232h_x_mm));
echo(str("gap between the board edge and each LONG wall (mm): ", fit_gap_y,
         " -- FT232H needs ", ft232h_post_ht + ft232h_pcb_t,
         ", switch nest needs ", kan28_body_depth));

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


// Assertion: the FT232H must clear the heatsink -- in BOTH axes.
//
// The first version of this compared X only and rejected a position that was
// perfectly fine, pushing the holder 50mm from where it belonged. The board
// sits against the top wall at board y around 0 to 5, while the heatsink zone
// is y 23.5 to 66.5, so their X ranges can overlap freely. Checking one axis
// of a two-axis clearance is worse than not checking, because it looks like a
// check.
ft232h_x0 = ft232h_x_mm - ft232h_pcb_mm[0]/2;
ft232h_x1 = ft232h_x_mm + ft232h_pcb_mm[0]/2;
// How far the holder reaches off the wall, converted to a board-local Y so it
// can be compared with the heatsink zone. Before item 5 the wall was 1.2mm from
// the board edge and the two were treated as the same number; with a 10.2mm gap
// they are not, and the check would have been 9mm pessimistic.
ft232h_y1 = ft232h_post_ht + ft232h_pcb_t - fit_gap_y;
hs_x0 = heatsink_center_mm[0] - heatsink_lwh_mm[0]/2 - heatsink_xy_margin_mm;
hs_x1 = heatsink_center_mm[0] + heatsink_lwh_mm[0]/2 + heatsink_xy_margin_mm;
hs_y0 = heatsink_center_mm[1] - heatsink_lwh_mm[1]/2 - heatsink_xy_margin_mm;
ft232h_overlaps = (ft232h_x1 > hs_x0) && (ft232h_x0 < hs_x1) && (ft232h_y1 > hs_y0);
echo(str("FT232H spans board x ", ft232h_x0, "..", ft232h_x1,
         ", reaching ", ft232h_y1, "mm off the top wall; heatsink zone y starts ",
         hs_y0));
assert(!ft232h_overlaps, "FT232H overlaps the heatsink zone in both axes");

// Open area of the vent grid, so a change to the hole size or pitch shows
// its effect immediately instead of being guessed at.
vent_cell_area = (sqrt(3)/2) * vent_hole_pitch * vent_hole_pitch;
vent_open_area = (vent_shape == "hex")
    ? (sqrt(3)/2) * vent_hole_d * vent_hole_d
    : PI/4 * vent_hole_d * vent_hole_d;
echo(str("vent: ", vent_shape, " ", vent_hole_d, "mm at ", vent_hole_pitch,
         "mm pitch -> web ", vent_hole_pitch - vent_hole_d, "mm, open area ",
         round(1000 * vent_open_area / vent_cell_area)/10, "%"));

// Checked per AXIS. The long walls stand 10.2mm off the board after item 5, so
// a single lip_ledge that is fine on the short walls leaves the board's two
// long edges hanging in air -- exactly the kind of thing a whole-case scalar
// hides.
lip_bearing_x_mm = lip_ledge_x - fit_gap_x;
lip_bearing_y_mm = lip_ledge_y - fit_gap_y;
echo(str("lip bearing under board edge (mm) -- short walls: ", lip_bearing_x_mm,
         ", long walls: ", lip_bearing_y_mm));
assert(lip_bearing_x_mm >= 1.0,
       str("retaining lip only reaches ", lip_bearing_x_mm,
           "mm under the board's short edges. Increase lip_ledge."));
assert(lip_bearing_y_mm >= 1.0,
       str("retaining lip only reaches ", lip_bearing_y_mm,
           "mm under the board's long edges. Increase lip_bearing_target."));

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
