// QMTECH XC7K325T Dev Board -- two-part case (base tray + lid)
// Parametric OpenSCAD, 3D-print friendly (FDM, no supports needed).
// v2: taller for a heatsink, closed lid with discrete connector holes
// (not an open face), display + thermal-sensor mounting provisions.
//
// Sources:
// - "QMTECH XC7K325T DEV BOARD USER MANUAL V01" Figure 2-1 (board
//   outline: 160x90mm) and the manual's cover-page top-view photo
//   (connector layout).
// - colneech-dev/odo-miner-cyclonev's docs/DISPLAY_WIRING.md (display
//   module part number) and docs/FAN_SENSOR_WIRING.md (thermal sensor)
//   -- a real, hardware-verified reference build for the same class of
//   "FPGA dev board + status display + thermal sensor" appliance.
//
// ============================================================
// DESIGN DECISIONS -- read before printing
// ============================================================
// 1. TWO PARTS: a base tray (unchanged in spirit from v1: board sits on
//    a perimeter lip, HDMI/TF/USB/RJ45 windows on one edge) plus a LID
//    that actually closes the top, with individual cutouts for the CM4
//    connector, 3 pin headers, DC jack, micro-USB, and a switch cluster
//    -- replacing v1's "leave the whole top edge open" approach now that
//    "not fully open, proper holes" is the ask. The lid seats on a
//    friction skirt and is secured with 4 corner screws into full-height
//    bosses (separate from the shorter under-board standoffs).
// 2. TALLER: wall_height went from 16mm to 34mm to clear a passive
//    heatsink on the Kintex-7 (component_clearance_mm below is the
//    reserved height above the board's top surface -- tune this to
//    whatever heatsink you actually use; 34mm total case height covers
//    a common ~20mm heatsink with margin, not a specific datasheet).
// 3. HOLE POSITIONS ARE STILL ESTIMATES. Same caveat as v1: the CM4
//    connector/header/DC-jack/micro-USB/switch positions are read
//    proportionally off the manual's cover photo, not measured, and
//    every cutout is deliberately oversized (cutout_margin) to absorb
//    that. Nudge the position tables below once you have the board.
// 4. DISPLAY: sized for the **KMRTM28028-SPI** (2.8" 240x320 ILI9341 +
//    XPT2046 touch, 14-pin header) -- the exact module
//    colneech-dev/odo-miner-cyclonev verified on real hardware for this
//    class of build. This board's own manual doesn't mention a display,
//    so wiring it needs the board's 50-pin extension header (JP5) or
//    the CM4's spare GPIO lines (GPIO24-27, unused by
//    ../hdl/odocrypt_gpio_wrapper.v) -- SPI needs more signal lines
//    (CS/DC/RST/SCLK/MOSI/MISO + touch CS/IRQ) than the 4 spare CM4
//    lines alone provide, so JP5 is the more realistic path. RTL/driver
//    for this is NOT implemented anywhere in this repo yet -- this file
//    only adds the physical mounting provision.
// 5. THERMAL SENSOR: a DS18B20 (TO-92, 3-wire: VDD/GND/DATA), the same
//    part odo-miner-cyclonev uses, verified there tracking real load
//    (34-49 deg C). It mounts against/near the heatsink, not through a
//    panel cutout of its own size -- this lid just adds a small cable
//    pass-through grommet hole near the ventilation grille for its
//    3 wires to route out to JP5 or a spare CM4 GPIO.
// 6. Same square-corners note as v1 applies (hull()-based rounding
//    previously broke cutout subtraction silently -- confirmed by A/B
//    vertex-count testing). This file never used rounding to begin with.
// 7. Print a fit-check first, same as v1 -- these are estimates.
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
standoff_clearance   = 3.0;  // gap under the board for bottom-side components/solder
component_clearance_mm = 28; // reserved height ABOVE the board's top surface for
                              // the tallest thing on it (Kintex-7 + heatsink) --
                              // TUNE to your actual heatsink; not a measured value
wall_height = component_clearance_mm + 6; // a little extra above the heatsink

// ---- Lid ----
lid_thickness   = 2.4;
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
// [name, x, y, w, h] -- all estimated proportionally from the manual's
// cover photo; every window gets +cutout_margin on all sides below.
lid_top_cutouts_mm = [
    ["CM4_CONN",  8,  0, 62, 38],  // CM4 card-edge connector access
    ["HEADER_1", 78,  0, 16, 12],
    ["HEADER_2", 98,  0, 16, 12],
    ["HEADER_3", 118, 0, 16, 12],
    ["USB_MICRO",140, 2, 12,  8],
    ["SWITCHES", 152, 6, 10, 14],
];
dc_jack_center_mm = [158, 20]; // round hole, DC barrel jack
dc_jack_diameter  = 12;

// Ventilation grille over the FPGA (position estimated: roughly
// center-left of the board's open lower area, per the manual photo --
// deliberately kept clear of the CM4_CONN/HEADER/DC-jack cluster above
// (all of which sit at y<44) and the display footprint below (x>93) so
// none of these three regions overlap. A slotted array, not a single
// big hole, for some stiffness.
vent_center_mm = [50, 70];
vent_area_mm   = [70, 35];
vent_slot_w    = 3;
vent_slot_gap  = 3;

// DS18B20 sensor cable pass-through (near the vent grille -- the sensor
// itself mounts against/near the heatsink, this is just for its 3 wires).
// Also kept clear of CM4_CONN (y<44) and the vent grille itself.
sensor_hole_center_mm = [50, 48];
sensor_hole_d = 5;

// ---- Display mounting (KMRTM28028-SPI 2.8" ILI9341+XPT2046, see note 4
// above). Module PCB footprint and hole spacing below are TYPICAL for
// this class of 14-pin 2.8" SPI TFT module family, not this exact
// module's datasheet dimensions -- verify against your actual module
// before printing; nudge display_pcb_mm / display_hole_spacing_mm if
// your module differs. Mounted on the lid, offset from the connector
// cutouts above (there's no room for it near the CM4/header cluster). ----
display_pcb_mm       = [76, 53];  // module outline, W x H, typical for this class
display_active_mm    = [58, 44];  // approx viewable/bezel cutout area, centered
display_hole_spacing_mm = [70, 47]; // corner mounting-hole spacing, centered on module
display_center_mm    = [122, 66]; // position on the lid -- right side, clear of
                                   // the connector cluster and vent grille
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

module lid_vent_grille() {
    cx = board_origin[0] + vent_center_mm[0];
    cy = board_origin[1] + vent_center_mm[1];
    n = floor(vent_area_mm[0] / (vent_slot_w + vent_slot_gap));
    total_w = n * vent_slot_w + (n-1) * vent_slot_gap;
    start_x = cx - total_w/2;
    for (i = [0:n-1])
        translate([start_x + i*(vent_slot_w+vent_slot_gap), cy - vent_area_mm[1]/2, -1])
            cube([vent_slot_w, vent_area_mm[1], lid_thickness + 2]);
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
            lid_vent_grille();
            lid_sensor_passthrough();
            lid_display_cutout();
        }
        lid_display_standoffs();
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
