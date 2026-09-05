#!/usr/bin/env bash
# Wait for the in-flight routes, then run the queued work in priority order.
#
# Everything here is gated on the two baseline routes finishing, because each
# needs ~3.3 GB and the next step needs ~10 GB. Running them together is what
# turned two ~40-minute jobs into multi-hour ones earlier in this session:
# memory fit, but 8 cores did not, and router2 is heavily threaded.
#
# Step order is by value, not convenience:
#
#   1. hdlname_recover coverage on the REAL netlist.
#      PR YosysHQ/yosys#6145 claims the algorithm resolves 69975/69975 cells on
#      this design. That number came from the PYTHON PROTOTYPE on the 0.62
#      netlist; the shipped C++ pass has only ever been run on toy designs
#      (48 cells, and a synthetic pipeline where it managed 16 of 293 because
#      the RTL names no internal signals). Verifying a public claim outranks
#      any new experiment.
#
#   2. chipdb regeneration from the merged tree, removing the generator/binary
#      revision mismatch documented in build-chipdb.sh.
#
# Deliberately NOT queued: any further region/floorplan geometry. Measured three
# times, never converged. And no wire-demand sweep until the baseline and seed
# spread from the routes are in hand -- with ~20% seed variation, a single run
# cannot separate a real effect from noise.
set -uo pipefail
cd "$(dirname "$0")"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Wait on the actual processes. Match the log filenames rather than a generic
# pattern: `pgrep -f nextpnr` also matches this script's own command line, which
# has silently broken several waits in this session.
wait_for_routes() {
    while pgrep -f "am01_qmtech_top_v68base.pnr.log" >/dev/null 2>&1 ||
          pgrep -f "am01_qmtech_top_v68s7.pnr.log" >/dev/null 2>&1; do
        sleep 60
    done
}

log "waiting for the two baseline routes"
wait_for_routes
log "routes finished"

for t in v68base v68s7; do
    L="out_nm1_nosr/am01_qmtech_top_$t.pnr.log"
    printf '  %-9s %s\n' "$t" "$(grep -oE 'iter=[0-9]+ .*unrouted=[0-9]+' "$L" 2>/dev/null | tail -1)"
    printf '  %-9s %s\n' "" "$(grep 'clk_h' "$L" 2>/dev/null | grep MHz | tail -1)"
done

# ---------------------------------------------------------------- step 1
log "STEP 1: hdlname_recover coverage on the real netlist"
. "$(dirname "$0")/toolchain.sh"
resolve_tool YOSYS yosys || true
$YOSYS -p "read_verilog -sv ../hdl/am01_qmtech_top_nm1.v; \
           read_verilog -sv ../hdl/clk_gen_hash.v; \
           read_verilog -sv ../hdl/odocrypt_gpio_wrapper.v; \
           read_verilog -sv ../../../hdl/odocrypt/encrypt.v; \
           read_verilog -sv ../../../hdl/odocrypt/keccak800.v; \
           read_verilog -sv ../../../hdl/odocrypt/miner.v; \
           read_verilog -sv ../../../hdl/odocrypt/atomminer_misc.v; \
           synth_xilinx -top am01_qmtech_top -family xc7 -flatten; \
           hdlname_recover; \
           write_json out_nm1_nosr/am01_qmtech_top_hdl.json" \
    > hdlname_real.log 2>&1
log "  yosys exit=$?"
grep -E "set hdlname on|recoverable scope|already had|conflicting" hdlname_real.log | sed 's/^/    /'

# The number PR #6145 will be judged on.
python3 - <<'PY'
import json
try:
    d = json.load(open("out_nm1_nosr/am01_qmtech_top_hdl.json"))
except Exception as e:
    print("    could not read netlist: %s" % e); raise SystemExit
m = d["modules"]
top = next((k for k in m if m[k].get("attributes", {}).get("top")), list(m)[0])
cells = {k: v for k, v in m[top]["cells"].items() if v["type"] != "$scopeinfo"}
have = sum(1 for v in cells.values() if "hdlname" in v.get("attributes", {}))
print("    REAL-DESIGN COVERAGE: %d / %d cells carry hdlname (%.2f%%)"
      % (have, len(cells), 100.0 * have / max(1, len(cells))))
print("    PR #6145 claims 69975/69975 for the prototype -- compare before trusting it")
PY

# ---------------------------------------------------------------- step 2
log "STEP 2: native floorplan on the real netlist (no scripts)"
resolve_tool NEXTPNR nextpnr-xilinx || true
NEXTPNR_ISO_HEURISTIC=1 $NEXTPNR \
    --chipdb "$PWD/chipdb/xc7k325tffg676-1.bin" \
    --json out_nm1_nosr/am01_qmtech_top_hdl.json \
    --xdc ../xdc/qmtech_xc7k325t_pinout.xdc \
    --freq 133.33 --floorplan-hierarchy --no-route \
    --log out_nm1_nosr/am01_qmtech_top_hdlfp.pnr.log > /dev/null 2>&1
log "  nextpnr exit=$?"
grep -E "Hierarchy floorplan|device extent|depth [0-9]+:|banded|left free" \
    out_nm1_nosr/am01_qmtech_top_hdlfp.pnr.log 2>/dev/null | head -8 | sed 's/^/    /'

log "queued work complete"
