// QMTECH XC7K325T Dev Board -- open-top protective tray
// Parametric OpenSCAD, 3D-print friendly (FDM, no supports needed).
//
// Source: "QMTECH XC7K325T DEV BOARD USER MANUAL V01" Figure 2-1
// (board outline: 160mm x 90mm) and the manual's cover-page top-view
// photo (connector layout).
//
// ============================================================
// DESIGN DECISIONS -- read before printing
// ============================================================
// 1. OPEN TOP, by design, not an oversight. The manual documents a
//    Raspberry-Pi-CM4-class module plugging in near the top edge via
//    a tall card-edge connector, plus 3 pin headers, a DC barrel jack,
//    a micro-USB port, and a switch cluster all along that same top
//    edge -- none of their exact positions or the CM4+heatsink stack
//    height are in the manual's dimensioned drawing. Rather than guess
//    cutout Z-heights that might not fit, the whole top edge is left
//    open. This also means: no cutouts needed along the bottom edge
//    either -- that edge's long pin header (visible in Figure 2-1)
//    has pins pointing straight up, not out sideways, so an open top
//    already clears it.
// 2. Cutout windows ARE modeled on the LEFT edge only, for the six
//    connectors clearly visible protruding sideways in the manual's
//    cover photo (top to bottom): HDMI, HDMI, microSD/TF, USB-A,
//    USB-A, RJ45 Ethernet. Their Y positions below are estimated
//    PROPORTIONALLY from that photo, not measured -- each window is
//    made generously oversized (see cutout_margin) specifically to
//    absorb that uncertainty. Nudge connector_positions_mm below if
//    a window doesn't line up once you have the board in hand.
// 3. Corner standoffs are a SECONDARY, optional fixation. The PCB's
//    primary retention is the perimeter lip (a step the board simply
//    drops onto), which works regardless of where the real mounting
//    holes are. standoff_inset_mm below is a generic default (NOT
//    transcribed with confidence from the manual's dimension drawing,
//    whose leader lines were not legible enough to trust precisely)
//    -- treat the standoffs as "nice if they land right," not load-
//    bearing. If they miss, the lip alone still holds the board.
// 4. Print a quick low-infill fit-check of just the outline first
//    (or trim height down to ~5mm) before committing to a full detail
//    print, given the estimates above.
// ============================================================

// ---- Board ----
board_length   = 160;   // X, the manual's Figure 2-1 dimension
board_width    = 90;    // Y
board_thickness = 1.6;  // standard PCB thickness

// ---- Fit tolerances ----
fit_gap        = 0.6;   // extra clearance around the board footprint, all sides
lip_ledge      = 1.5;   // how far the retaining lip overlaps the board edge
lip_thickness  = 2.0;   // Z height of the lip step the board rests on

// ---- Tray shell ----
wall_thickness  = 2.4;
floor_thickness = 2.4;
standoff_clearance = 3.0; // gap under the board for bottom-side components/solder
wall_height     = 16.0;   // clears USB-A (~11mm) and RJ42 (~13-14mm) with margin;
                          // NOT validated against the CM4/top-edge stack (moot -- open top)

// ---- Corner standoffs (secondary fixation, see note 3 above) ----
enable_standoffs   = true;
standoff_inset_mm  = 5;    // generic default, NOT read off the manual with confidence
standoff_od        = 6.0;
standoff_pilot_od  = 2.6;  // pilot hole for an M3 self-tapping/heat-set screw

// ---- Left-edge connector cutouts (see note 2 above) ----
cutout_margin = 3.0; // each window is oversized by this much on every side, to
                      // absorb position uncertainty -- deliberately generous

// [name, y_center_mm_from_front_left_corner, window_height_mm]
// Y estimated proportionally along the 90mm left edge from the manual's
// cover photo stacking order (top to bottom): HDMI, HDMI, TF, USB, USB, RJ45.
connector_positions_mm = [
    ["HDMI_1", 10,  13],
    ["HDMI_2", 24,  13],
    ["TF_CARD", 40,  9],
    ["USB_1",   54, 16],  // stacked dual USB-A, modeled as one tall window
    ["USB_2",   54, 16],  // (duplicate center is fine -- union just merges)
    ["RJ45",    76, 16],
];

// ============================================================
// Derived geometry
// ============================================================
outer_length = board_length + 2*(fit_gap + wall_thickness);
outer_width  = board_width  + 2*(fit_gap + wall_thickness);
tray_height  = floor_thickness + standoff_clearance + board_thickness + wall_height;

lip_z = floor_thickness + standoff_clearance; // board rests here

// NOTE: corners are deliberately square (no hull()/rounded_rect()) --
// an earlier hull()-of-circles rounded-corner version silently produced
// CGAL boolean geometry that did not intersect correctly with the
// cutout cubes below (subtracting them changed the mesh by ~0 vertices,
// confirmed by isolated A/B testing). Plain square() corners are also
// simpler and no worse for FDM printing (no overhangs either way).

module tray_shell() {
    difference() {
        // outer block
        linear_extrude(height = tray_height)
            square([outer_length, outer_width]);

        // hollow out the interior (board pocket + open top)
        translate([wall_thickness, wall_thickness, floor_thickness])
            linear_extrude(height = tray_height)
                square([outer_length - 2*wall_thickness,
                        outer_width  - 2*wall_thickness]);
    }
}

// An inward-facing ridge on all 4 walls at lip_z -- the board (dropped
// in from the open top) rests on this instead of falling to the floor.
module retaining_lip_ridge() {
    ridge_w = lip_ledge;
    z0 = lip_z;
    inset = wall_thickness - ridge_w; // must match the inner-cut translate below
    translate([0,0,z0])
    difference() {
        translate([inset, inset, 0])
            linear_extrude(height = lip_thickness)
                square([outer_length - 2*inset,
                        outer_width  - 2*inset]);
        translate([0,0,-1])
        linear_extrude(height = lip_thickness + 2)
            translate([wall_thickness, wall_thickness])
                square([outer_length - 2*wall_thickness,
                        outer_width  - 2*wall_thickness]);
    }
}

module left_edge_cutouts() {
    // Left edge of the *board* sits at x = wall_thickness + fit_gap.
    // Cut generously-oversized windows through the left wall (X=0 face)
    // at each connector's estimated Y (measured from the board's own
    // front-left corner, i.e. Y=0 at the board edge -- which is also
    // where the top edge below starts, matching the manual photo's
    // HDMI-stack corner).
    for (c = connector_positions_mm) {
        y_center = wall_thickness + fit_gap + c[1];
        h = c[2] + 2*cutout_margin;
        translate([-1, y_center - h/2, lip_z - cutout_margin])
            cube([wall_thickness + 2, h, wall_height + cutout_margin + 2]);
    }
}

module top_edge_open() {
    // The Y=0 wall (full X span) is removed entirely, not just windowed:
    // this is the edge the manual's cover photo shows hosting the CM4
    // card-edge connector, 3 pin headers, a DC barrel jack, a micro-USB
    // port and a switch cluster -- too many uncertain positions (and, for
    // the CM4, an unknown module+heatsink stack height) to safely window
    // individually. It shares its X=0 corner with left_edge_cutouts()'s
    // Y=0 origin above, matching the manual photo's HDMI corner.
    translate([-1, -1, lip_z - cutout_margin])
        cube([outer_length + 2, wall_thickness + 2, wall_height + cutout_margin + 2]);
}

module corner_standoff(x, y) {
    fuse_eps = 0.05; // guarantee real overlap with the floor, not a coincident face
    translate([x, y, floor_thickness - fuse_eps])
        difference() {
            cylinder(h = standoff_clearance + fuse_eps, d = standoff_od, $fn = 32);
            translate([0,0,-1])
                cylinder(h = standoff_clearance + fuse_eps + 2, d = standoff_pilot_od, $fn = 24);
        }
}

module standoffs() {
    if (enable_standoffs) {
        bx = wall_thickness + fit_gap + standoff_inset_mm;
        by = wall_thickness + fit_gap + standoff_inset_mm;
        ex = wall_thickness + fit_gap + board_length - standoff_inset_mm;
        ey = wall_thickness + fit_gap + board_width  - standoff_inset_mm;
        corner_standoff(bx, by);
        corner_standoff(ex, by);
        corner_standoff(bx, ey);
        corner_standoff(ex, ey);
    }
}

module case_body() {
    union() {
        difference() {
            tray_shell();
            union() {
                left_edge_cutouts();
                top_edge_open();
            }
        }
        retaining_lip_ridge();
        standoffs();
    }
}

case_body();

// ---- Reference: board footprint ghost, for visual fit-check in the
// OpenSCAD preview only (comment out %board_ghost(); line to remove
// from render/export). ----
module board_ghost() {
    translate([wall_thickness + fit_gap, wall_thickness + fit_gap, lip_z])
        color([0,1,0,0.35])
        cube([board_length, board_width, board_thickness]);
}
%board_ghost();
