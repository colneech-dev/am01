// QMTECH XC7K325T Dev Board -- two-part case (base tray + lid)
// Parametric OpenSCAD, 3D-print friendly (FDM, no supports needed).
// v3: real heatsink part number sizes a raised chimney over the FPGA
// only (not a uniformly tall case); CM4 cutout REMOVED -- it's a
// low-profile mezzanine module, not something needing panel access.
//
// Sources:
// - "QMTECH XC7K325T DEV BOARD USER MANUAL V01" Figure 2-1 (board
//   outline: 160x90mm) and the manual's cover-page top-view photo
//   (connector layout).
// - colneech-dev/odo-miner-cyclonev's docs/DISPLAY_WIRING.md (display
//   module part number) and docs/FAN_SENSOR_WIRING.md (thermal sensor)
//   -- a real, hardware-verified reference build for the same class of
//   "FPGA dev board + status display + thermal sensor" appliance.
// - Ohmite/Arcol BGAH270-175E datasheet (27x27x17.5mm BGA heatsink,
//   sized for the exact 27x27mm body of this chip's FFG676 package).
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
// 2. NO CM4 CUTOUT. v2 had one; it was wrong. The CM4 mates via two
//    100-pin board-to-board connectors at 1.5-3.0mm stack height, and
//    the module itself is only 4.7mm thick -- total ~6.2-7.7mm above
//    the carrier board (Raspberry Pi CM4 datasheet). That's a fully
//    internal, low-profile mezzanine, not something needing external
//    access: its HDMI/USB/Ethernet/etc. are already broken out to
//    *this* board's own edge connectors (the ones left_edge_cutouts()
//    already handles). general_clearance_mm below covers it with
//    margin to spare, no panel opening required.
// 3. SHORT EVERYWHERE EXCEPT OVER THE FPGA. general_clearance_mm (11mm)
//    replaces v2's uniform 28mm -- realistic for the CM4 stack (up to
//    7.7mm) plus modest wiring room, not a heatsink-driven guess. A
//    raised, open-top, vented "chimney" (lid_fpga_chimney_*() modules)
//    sits only over the FPGA/heatsink footprint, reaching the extra
//    height the heatsink actually needs -- see chimney_protrusion_mm's
//    derivation below, traceable to the BGAH270-175E's real 17.5mm.
// 4. HOLE POSITIONS ARE STILL ESTIMATES. The header/DC-jack/micro-USB/
//    switch positions, and the FPGA's location under the chimney, are
//    read proportionally off the manual's cover photo, not measured --
//    none of it is in the manual's dimensioned drawing. Every cutout is
//    deliberately oversized (cutout_margin) to absorb that. Nudge the
//    position tables below once you have the board.
// 5. DISPLAY: sized for the **KMRTM28028-SPI** (2.8" 240x320 ILI9341 +
//    XPT2242 touch, 14-pin header) -- the exact module
//    colneech-dev/odo-miner-cyclonev verified on real hardware for this
//    class of build. Repositioned (from v2) to the lid's left-of-
//    chimney area, the only region with enough free space once the
//    header/DC-jack cluster and the chimney footprint are laid out --
//    verified by explicit numeric range-checking this time, not just
//    eyeballing a render (see v2's collision bug, fixed then re-broken
//    then fixed again -- this file's history is a lesson in checking
//    the numbers, not just the picture). This board's manual doesn't
//    mention a display; wiring it needs the board's 50-pin extension
//    header (JP5) or spare CM4 GPIO lines -- SPI needs more signal
//    lines (CS/DC/RST/SCLK/MOSI/MISO + touch CS/IRQ) than the 4 spare
//    CM4 lines (GPIO24-27, unused by ../hdl/odocrypt_gpio_wrapper.v)
//    provide, so JP5 is the realistic path. RTL/driver for this is NOT
//    implemented anywhere in this repo yet -- this file only adds the
//    physical mounting provision.
// 6. THERMAL SENSOR: a DS18B20 (TO-92, 3-wire: VDD/GND/DATA), the same
//    part odo-miner-cyclonev uses, verified there tracking real load
//    (34-49 deg C). It mounts against/near the heatsink, not through a
//    panel cutout of its own size -- this lid just adds a small cable
//    pass-through hole next to the chimney for its 3 wires to route out
//    to JP5 or a spare CM4 GPIO.
// 7. Same square-corners note as v1/v2: `hull()`-based rounding
//    previously broke cutout subtraction silently -- confirmed by A/B
//    vertex-count testing. This file never used rounding to begin with.
// 8. Print a fit-check first, same as v1/v2 -- these are estimates.
// ============================================================

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

// General clearance above the board's top surface, for EVERYTHING except
// the FPGA/heatsink (which gets its own chimney below): the CM4 mezzanine
// stack (max ~7.7mm: 4.7mm module + 3.0mm connector, Raspberry Pi CM4
// datasheet) plus a few mm for wire dressing (display/sensor cables).
// This replaces v2's component_clearance_mm, which sized the WHOLE case
// to the heatsink -- wrong, since the CM4 doesn't need anywhere near
// that height and most of the board shouldn't pay for it.
general_clearance_mm = 11;
wall_height = general_clearance_mm + 3; // = 14mm, a little buffer above the CM4 stack

// ---- Lid thickness (defined here, ahead of its normal section below,
// because chimney_protrusion_mm needs it) ----
lid_thickness = 2.4;

// ---- FPGA heatsink chimney -------------------------------------------
// Sized from a real part: Ohmite/Arcol BGAH270-175E, 27x27x17.5mm --
// dimensioned for exactly this chip's FFG676 package body (27x27mm).
// The chimney is a raised, open-top, vented parapet on the LID directly
// over the FPGA, not a uniformly taller case -- see lid_fpga_chimney_*()
// below. Position is read off hardware/Dimension(Board_Top_View).pdf in
// ChinaQMTECH/QMTECH_Kintex-7_Development_Board (the vendor's own real
// ECAD dimension export) -- the BGA footprint sits at roughly the board's
// horizontal-center, ~half way down -- still an estimate (no exact
// leader-line coordinate for the die center is given), but a materially
// better one than v2's photo-proportional guess.
heatsink_lwh_mm       = [27, 27, 17.5]; // BGAH270-175E, L x W x H
heatsink_center_mm    = [100, 50];      // FPGA package center, board-local XY
chimney_xy_margin_mm  = 8;              // clearance around the heatsink body,
                                         // each side (position uncertainty +
                                         // the heatsink's own mounting clips)
chimney_wall_t        = 2.0;
vent_slot_w            = 3;   // chimney wall vent slots (see lid_fpga_chimney_vents())
vent_slot_gap          = 3;
fpga_chip_and_pad_mm  = 2.0;  // BGA body + thermal pad, above the PCB surface
heatsink_assembly_margin_mm = 3.0; // safety margin (adhesive squeeze-out, tolerance)

chimney_footprint_mm = [heatsink_lwh_mm[0] + 2*chimney_xy_margin_mm,
                          heatsink_lwh_mm[1] + 2*chimney_xy_margin_mm]; // = [43,43]
heatsink_total_clearance_mm = heatsink_lwh_mm[2] + fpga_chip_and_pad_mm
                               + heatsink_assembly_margin_mm; // = 22.5mm, PCB to top of stack
// How far the chimney has to stick up ABOVE the general lid surface to
// give the heatsink its 22.5mm, given the general case (wall_height +
// lid_thickness) only provides 14+2.4=16.4mm on its own:
chimney_protrusion_mm = max(1, heatsink_total_clearance_mm - (wall_height + lid_thickness));

// ---- Lid (lid_thickness is defined earlier -- see above) ----
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

// Ventilation is now cut into the chimney's own side walls (see
// lid_fpga_chimney_vents() below) rather than a separate flat grille --
// makes more physical sense for airflow over the actual heatsink, and
// there's no longer a free flat area to put one anyway once the CM4
// cutout is gone and the display needs the remaining room (checked
// below with real numbers, not eyeballed -- see the v2 changelog note
// about a collision bug caught that way).

// DS18B20 sensor cable pass-through, tucked into the gap between the
// display and the chimney (checked clear of both below).
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

// ---- FPGA heatsink chimney: a raised, open-top, vented parapet on top
// of the lid directly over the FPGA -- see design note 3 at the top of
// this file for why this is a step instead of a uniformly taller case,
// and the "FPGA heatsink chimney" parameter block for the height math.

module lid_fpga_chimney_bore() {
    // Hole straight through the lid panel, connecting the tray's
    // interior to the chimney above -- this is what actually lets the
    // heatsink (mounted on the board below) poke up into the chimney.
    cx = board_origin[0] + heatsink_center_mm[0];
    cy = board_origin[1] + heatsink_center_mm[1];
    translate([cx - chimney_footprint_mm[0]/2, cy - chimney_footprint_mm[1]/2, -1])
        cube([chimney_footprint_mm[0], chimney_footprint_mm[1], lid_thickness + 2]);
}

module lid_fpga_chimney_walls() {
    fuse_eps = 0.05; // overlap into lid_panel, same reason as lid_skirt()
    cx = board_origin[0] + heatsink_center_mm[0];
    cy = board_origin[1] + heatsink_center_mm[1];
    ow = chimney_footprint_mm[0];
    oh = chimney_footprint_mm[1];
    translate([cx - ow/2, cy - oh/2, lid_thickness - fuse_eps])
        difference() {
            linear_extrude(height = chimney_protrusion_mm + fuse_eps)
                square([ow, oh]);
            translate([chimney_wall_t, chimney_wall_t, -1])
                linear_extrude(height = chimney_protrusion_mm + fuse_eps + 2)
                    square([ow - 2*chimney_wall_t, oh - 2*chimney_wall_t]);
        }
}

module lid_fpga_chimney_vents() {
    // Slots through the two Y-facing chimney walls (front/back) for
    // passive convection airflow over the heatsink. Kept a couple mm
    // off the top/bottom edges of the wall for strut strength.
    cx = board_origin[0] + heatsink_center_mm[0];
    cy = board_origin[1] + heatsink_center_mm[1];
    ow = chimney_footprint_mm[0];
    oh = chimney_footprint_mm[1];
    slot_margin = 4; // keep slots off the corners
    n = max(1, floor((ow - 2*chimney_wall_t - 2*slot_margin) / (vent_slot_w + vent_slot_gap)));
    total_w = n*vent_slot_w + (n-1)*vent_slot_gap;
    start_x = cx - total_w/2;
    slot_h = max(1, chimney_protrusion_mm - 4); // clear of top/bottom wall edges
    for (i = [0:n-1])
        for (y0 = [cy - oh/2 - 1, cy + oh/2 - chimney_wall_t - 1])
            translate([start_x + i*(vent_slot_w+vent_slot_gap), y0, lid_thickness + 2])
                cube([vent_slot_w, chimney_wall_t + 2, slot_h]);
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
            lid_fpga_chimney_bore();
            lid_sensor_passthrough();
            lid_display_cutout();
        }
        union() {
            lid_display_standoffs();
            difference() {
                lid_fpga_chimney_walls();
                lid_fpga_chimney_vents();
            }
        }
    }
}

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
