# Pre-route hook: let the router actually fix hold.
#
# Vivado stops fixing hold on this design and says so, in every muxed build
# log since mux3:
#
#   WARNING: [Route 35-514] Design has a large number of hold violators.
#   Router is turning off hold fixing. Resolution: ... set_param
#   route.enableHoldExpnBailout 0. This can incur potentially very long
#   router run time.
#
# Four builds took that quick exit and reported 7,807-12,564 failing hold
# endpoints, which IMPLEMENTATION-REVIEW.md 4g/4h then misdiagnosed as
# structural two-clock skew. With the bailout off the same design converged to
# ZERO failing endpoints in 7h47m of routing (4i).
#
# THIS MUST BE A PRE-ROUTE HOOK, not a set_param in build_mux4.tcl.
# launch_runs spawns a separate Vivado process, so a parameter set in the
# parent never reaches the router -- it would look applied and do nothing,
# which is the same shape of mistake as the `if` that XDC silently discarded.
set_param route.enableHoldExpnBailout 0
puts "PRE-ROUTE: route.enableHoldExpnBailout = 0 -- hold fixing will not bail out"
puts "PRE-ROUTE: expect routing to take many hours; that is the point"
