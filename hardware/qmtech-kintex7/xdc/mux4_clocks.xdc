# Clock constraints for the 4-instance muxed experiment ONLY.
# Read by vivado/build_mux4.tcl, never by build_full.tcl.
#
# ---------------------------------------------------------------------
# Balance the two hash clock networks against each other.
#
# clk_h and clk_2x leave the same MMCM and then travel through two SEPARATE
# BUFGs on two separate global networks. Measured on the 4-instance muxed
# build, 2026-09-12:
#
#   Destination Clock Delay (clk_h,  BUFGCTRL_X0Y0)  4.956ns
#   Source      Clock Delay (clk_2x, BUFGCTRL_X0Y1)  4.084ns
#   Clock Path Skew                                  0.331ns
#   Data Path Delay                                  0.193ns
#
# The data arrives before the clock edge it is racing, which is a hold
# violation -- 12,545 of them, essentially every failing hold endpoint in
# that design, and all on clk_h <-> clk_2x crossings. Intra-clock hold was
# 19 endpoints. A post-route re-route with hold fixing moved not one
# picosecond (-0.413 -> -0.413), so this is not a routing problem.
# See hdl/odocrypt/IMPLEMENTATION-REVIEW.md section 4g.
#
# CLOCK_DELAY_GROUP asks the router to match insertion delay across the
# grouped clock nets, which is the direct answer to that measurement. The
# alternative is deleting the clk_h domain entirely and running everything on
# clk_2x with a clock enable -- correct, but a rewrite of the transform, the
# wrapper and the constraints. This is one property; try it first.
#
# ---------------------------------------------------------------------
# WHY THIS IS A SEPARATE FILE, which is the whole point of it.
#
# It first went into qmtech_xc7k325t_pinout.xdc wrapped in an `if` that
# skipped it when the clk_2x BUFG was absent -- because in the 2-instance
# SHIPPING design nothing consumes clk_2x and synthesis drops that BUFG (see
# clk_gen_hash.v, lines 68 and 201), so an unguarded set_property would have
# failed on a net that does not exist and taken the earning build with it.
#
# XDC files do not support `if`:
#
#   CRITICAL WARNING: [Designutils 20-1307] Command 'if' is not supported in
#   the xdc constraint file.
#
# The whole block was discarded and a 15-hour build ran with no constraint at
# all, reproducing the previous result and proving nothing. It was caught only
# by grepping the synthesis log for the confirmation message it should have
# printed -- the build itself reported success.
#
# A separate file read only by the muxed build needs no guard, because the
# condition the guard was testing is the same condition that decides whether
# the file is read. Constraints that apply to one build belong in a file for
# that build.
#
# NOTE: VIVADO ONLY, like most constraints here. nextpnr's XDC parser keeps
# only set_property, create_clock and set_multicycle_path, and while this IS a
# set_property, CLOCK_DELAY_GROUP is not a property openXC7 acts on.
# ---------------------------------------------------------------------

set_property CLOCK_DELAY_GROUP hash_clk_grp \
    [get_nets -of_objects [get_pins clk_gen_hash_inst/bufg_clk_2x/O]]
set_property CLOCK_DELAY_GROUP hash_clk_grp \
    [get_nets -of_objects [get_pins clk_gen_hash_inst/bufg_clk_h/O]]
