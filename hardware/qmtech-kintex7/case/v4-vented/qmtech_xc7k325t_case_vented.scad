// QMTECH XC7K325T Dev Board -- two-part case (base tray + lid)
// Parametric OpenSCAD, 3D-print friendly (FDM, no supports needed).
// v4: FULLY ENCLOSED. v3's open-top vented chimney is gone -- the whole
// box is now uniformly tall enough to close over the heatsink, no
// opening above it. This file is a shared template with two variant
// knobs (VARIANT_WALL_HEIGHT, VARIANT_VENTED) near the top; see
// ../README.md for the three generated variants (sealed / vented /
// tall-xl) and why each exists. CM4 cutout stays REMOVED (v3 finding:
// it's a low-profile mezzanine module, not something needing panel
// access).
//
// Sources:
// - "QMTECH XC7K325T DEV BOARD USER MANUAL V01" Figure 2-1 (board
//   outline: 160x90mm) and the manual's cover-page top-view photo
//   (connector layout).
// - ChinaQMTECH/QMTECH_Kintex-7_Development_Board's
//   hardware/Dimension(Board_Top_View).pdf -- the vendor's own real
//   Allegro ECAD dimension export, used to refine the FPGA position and
//   cross-check the header/DC-jack layout.
// - colneech-dev/odo-miner-cyclonev's docs/DISPLAY_WIRING.md (display
//   module part number) and docs/FAN_SENSOR_WIRING.md (thermal sensor)
//   -- a real, hardware-verified reference build for the same class of
//   "FPGA dev board + status display + thermal sensor" appliance.
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
// 1. TWO PARTS: a base tray (board sits on a perimeter lip, HDMI/TF/
//    USB/RJ45 windows on one edge) plus a closed LID with individual
//    cutouts for the 3 pin headers, DC jack, micro-USB, and a switch
//    cluster. The lid seats on a friction skirt and is secured with
//    4 corner screws into full-height bosses (separate from the
//    shorter under-board standoffs).
// 2. NO CM4 CUTOUT. The CM4 mates via two 100-pin board-to-board
//    connectors at 1.5-3.0mm stack height, and the module itself is
//    only 4.7mm thick -- total ~6.2-7.7mm above the carrier board
//    (Raspberry Pi CM4 datasheet). That's a fully internal, low-profile
//    mezzanine, not something needing external access: its HDMI/USB/
//    Ethernet/etc. are already broken out to *this* board's own edge
//    connectors (the ones left_edge_cutouts() already handles).
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
// 5. HOLE POSITIONS ARE STILL ESTIMATES. The header/DC-jack/micro-USB/
//    switch positions, and the FPGA's location, are read proportionally
//    off the manual's cover photo and cross-checked against the
//    vendor's real dimension PDF, not measured to exact coordinates.
//    Every cutout is deliberately oversized (cutout_margin) to absorb
//    that. Nudge the position tables below once you have the board.
// 6. DISPLAY: sized for the **KMRTM28028-SPI** (2.8" 240x320 ILI9341 +
//    XPT2242 touch, 14-pin header) -- the exact module
//    colneech-dev/odo-miner-cyclonev verified on real hardware for this
//    class of build. Mounted portrait (rotated 90 deg from its natural
//    orientation) in the lid's left region, the only area with enough
//    free space once the header/DC-jack cluster and the FPGA vent zone
//    are laid out -- verified by explicit numeric range-checking, not
//    eyeballing a render. This board's manual doesn't mention a
//    display; wiring it needs the board's 50-pin extension header
//    (JP5) or spare CM4 GPIO lines -- SPI needs more signal lines
//    (CS/DC/RST/SCLK/MOSI/MISO + touch CS/IRQ) than the 4 spare CM4
//    lines (GPIO24-27, unused by ../hdl/odocrypt_gpio_wrapper.v)
//    provide, so JP5 is the realistic path. RTL/driver for this is NOT
//    implemented anywhere in this repo yet -- this file only adds the
//    physical mounting provision.
// 7. THERMAL SENSOR: a DS18B20 (TO-92, 3-wire: VDD/GND/DATA), the same
//    part odo-miner-cyclonev uses, verified there tracking real load
//    (34-49 deg C). It mounts against/near the heatsink, not through a
//    panel cutout of its own size -- this lid just adds a small cable
//    pass-through hole near the FPGA vent zone for its 3 wires to route
//    out to JP5 or a spare CM4 GPIO.
// 8. Same square-corners note as v1-v3: `hull()`-based rounding
//    previously broke cutout subtraction silently -- confirmed by A/B
//    vertex-count testing. This file never used rounding to begin with.
// 9. Print a fit-check first, same as v1-v3 -- these are estimates.
// ============================================================

// ============================================================
// VARIANT KNOBS -- these two lines are all that differ between the
// three generated files in ../v4-sealed/, ../v4-vented/, ../v4-tall-xl/.
// ============================================================
VARIANT_WALL_HEIGHT = 24;   // mm; 24 = sealed/vented, 36 = tall-xl
VARIANT_VENTED       = true;  // VENTED variant: perforated grid over the FPGA

// ---- Board ----
board_length    = 160;   // X, the manual's Figure 2-1 dimension
board_width     = 90;    // Y
board_thickness = 1.6;   // standard PCB thickness

// ---- Fit tolerances ----
fit_gap        = 0.6;    // extra clearance around the board footprint, all sides
lip_ledge      = 1.5;    // how far the retaining lip overlaps the board edge
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
// actually sold there. Position estimated from
// hardware/Dimension(Board_Top_View).pdf in
// ChinaQMTECH/QMTECH_Kintex-7_Development_Board (vendor's own ECAD
// dimension export) -- the BGA sits roughly at the board's horizontal
// center, about half way down; still not an exact leader-line
// coordinate, but materially better than a photo-proportional guess.
heatsink_lwh_mm       = [27, 27, 17.5]; // BGAH270-175E, L x W x H
heatsink_center_mm    = [100, 50];      // FPGA package center, board-local XY
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
enable_standoffs   = true;
standoff_inset_mm  = 5;
standoff_od        = 6.0;
standoff_pilot_od  = 2.6;

// ---- Corner lid-screw bosses (full height, separate from the above) ----
boss_od       = 7.0;
boss_pilot_od = 2.6;   // M3 self-tap/heat-set pilot
lid_screw_clearance_od = 3.4; // clearance hole through the lid itself

// ---- Left-edge connector cutouts (board-support wall, unchanged idea from v1) ----
cutout_margin = 3.0;
connector_positions_mm = [
    ["HDMI_1", 10,  13],
    ["HDMI_2", 24,  13],
    ["TF_CARD", 40,  9],
    ["USB_1",   54, 16],
    ["USB_2",   54, 16],
    ["RJ45",    76, 16],
];

// ---- Lid cutouts: top-edge connectors (X,Y = top-left corner of the
// window, measured from the board's own origin, i.e. offset by
// wall_thickness+fit_gap same as the board footprint below) ----
// [name, x, y, w, h] -- positions cross-checked against
// hardware/Dimension(Board_Top_View).pdf in
// ChinaQMTECH/QMTECH_Kintex-7_Development_Board (real ECAD dimension
// export), which shows 3 header rows and a DC-jack/micro-USB/switch
// cluster along this edge, at roughly these X positions -- still not
// exact leader-line coordinates, every window gets +cutout_margin on
// all sides below. NO CM4 cutout: the CM4 mates over two low-profile
// (1.5-3.0mm) board-to-board connectors and is fully covered by
// general_clearance_mm -- see design note 2 at the top of this file.
lid_top_cutouts_mm = [
    ["HEADER_1", 78,  0, 16, 12],
    ["HEADER_2", 98,  0, 16, 12],
    ["HEADER_3", 118, 0, 16, 12],
    ["USB_MICRO",140, 2, 12,  8],
    ["SWITCHES", 152, 6, 10, 14],
];
dc_jack_center_mm = [158, 20]; // round hole, DC barrel jack
dc_jack_diameter  = 12;

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
// with enough room once the header/DC-jack cluster (y<26) and the
// heatsink chimney (x=78.5-121.5, y=28.5-71.5) are laid out. Explicitly
// checked, not eyeballed:
//   PCB footprint  x=[8.5,61.5]  y=[7,83]   -- clear of chimney (61.5 < 78.5)
//   Active cutout  x=[13,57]     y=[16,74]  -- within board 0-160 x 0-90
//   Mount holes    x=[11.5,58.5] y=[10,80]
display_pcb_mm       = [53, 76];  // W x H, ROTATED from the module's native 76x53
display_active_mm    = [44, 58];  // ditto, rotated
display_hole_spacing_mm = [47, 70]; // ditto, rotated
display_center_mm    = [35, 45];  // left region of the lid, clear of chimney/headers
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

module retaining_lip_ridge() {
    ridge_w = lip_ledge;
    inset = wall_thickness - ridge_w;
    translate([0,0,lip_z])
    difference() {
        translate([inset, inset, 0])
            linear_extrude(height = lip_thickness)
                square([outer_length - 2*inset, outer_width - 2*inset]);
        translate([0,0,-1])
        linear_extrude(height = lip_thickness + 2)
            translate([wall_thickness, wall_thickness])
                square([outer_length - 2*wall_thickness,
                        outer_width  - 2*wall_thickness]);
    }
}

module left_edge_cutouts() {
    for (c = connector_positions_mm) {
        y_center = board_origin[1] + c[1];
        h = c[2] + 2*cutout_margin;
        translate([-1, y_center - h/2, lip_z - cutout_margin])
            cube([wall_thickness + 2, h, wall_height + cutout_margin + 2]);
    }
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
    if (enable_standoffs)
        for (p = corner_xy(standoff_inset_mm))
            corner_standoff(p[0], p[1]);
}

// Full-height bosses at the same 4 corners, for lid screws. Slightly
// further inset than the board-support standoffs so both fit without
// interfering (bosses sit just inside the wall corners).
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
    boss_inset = wall_thickness + 3;
    for (p = [
        [boss_inset, boss_inset],
        [outer_length - boss_inset, boss_inset],
        [boss_inset, outer_width - boss_inset],
        [outer_length - boss_inset, outer_width - boss_inset],
    ])
        lid_screw_boss(p[0], p[1]);
}

module base_tray() {
    union() {
        difference() {
            tray_shell();
            left_edge_cutouts();
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

module lid_screw_clearance_holes() {
    boss_inset = wall_thickness + 3;
    for (p = [
        [boss_inset, boss_inset],
        [outer_length - boss_inset, boss_inset],
        [boss_inset, outer_width - boss_inset],
        [outer_length - boss_inset, outer_width - boss_inset],
    ])
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

module lid_dc_jack_hole() {
    translate([board_origin[0] + dc_jack_center_mm[0],
                board_origin[1] + dc_jack_center_mm[1], -1])
        cylinder(h = lid_thickness + 2, d = dc_jack_diameter + 2*cutout_margin/2, $fn = 32);
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
                lid_skirt();
            }
            lid_screw_clearance_holes();
            lid_top_edge_cutouts();
            lid_dc_jack_hole();
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
