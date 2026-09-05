#!/usr/bin/env bash
# Route both A/B sides, once their synthesis has finished.
#
# WHY THIS IS SEPARATE FROM run_outreg_ab.sh
# ------------------------------------------
# build.sh's place & route step was broken for every invocation: it passed
# NEXTPNR_CRIT_DIST_EXP through a ${VAR:+NAME=VALUE} assignment prefix, which
# bash does not treat as an assignment (prefixes are recognised at parse time,
# before expansion), so it became the command name:
#     build.sh: NEXTPNR_CRIT_DIST_EXP=1.0: command not found
# CRIT_DIST defaults to 1.0, so this fired every time. It is fixed now, but the
# build.sh processes already running hold the OLD inode and will still fail at
# that step -- so their synthesis output is routed here instead, rather than
# throwing away two hours of work per side and starting over.
#
# STRICTLY SEQUENTIAL. yosys peaked at 10.6 GB on an 11 GB box; two nextpnr runs
# at ~2.4 GB each alongside anything else is how this machine ends up at zero
# available memory, which it has done twice today.
set -uo pipefail
cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7

NEXTPNR=/home/colin/src/nextpnr-xilinx-heatmap/build/nextpnr-xilinx
CHIPDB=./chipdb/xc7k325tffg676-1.bin
XDC=/mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/xdc/qmtech_xc7k325t_pinout.xdc
SEED="${SEED:-3}"          # the seed behind the 129.79 result; ~22 MHz spread
                           # here means both sides must pin the SAME one

echo $$ > .pid_route_ab
trap 'rm -f .pid_route_ab' EXIT

# Wait for the synthesis driver to finish, if it is still going.
if [ -f .pid_ab ]; then
    P=$(cat .pid_ab)
    echo "waiting for synthesis driver pid $P -- $(date -Is)"
    while kill -0 "$P" 2>/dev/null; do sleep 60; done
    echo "synthesis driver finished -- $(date -Is)"
fi

route () {   # route <tag> <dir>
    local tag="$1" dir="$2"
    local json="$dir/am01_qmtech_top.fp.json"
    [ -f "$json" ] || json="$dir/am01_qmtech_top.json"
    if [ ! -f "$json" ]; then
        echo "[$tag] NO NETLIST in $dir -- synthesis did not finish"
        return 1
    fi
    echo
    echo "=== [$tag] route $(basename "$json") -- $(date -Is) ==="
    env NEXTPNR_ARC_MAX_VISIT=2000000 \
        NEXTPNR_ROUTER2_MAX_STALL=250 \
        NEXTPNR_CRIT_DIST_EXP=1.0 \
        "$NEXTPNR" --chipdb "$CHIPDB" --json "$json" --xdc "$XDC" \
        --freq 133.33 --seed "$SEED" \
        --fasm "$dir/am01_qmtech_top.fasm" \
        --log "$dir/route.log" >"$dir/route.console" 2>&1
    echo "[$tag] exit $? -- $(date -Is)"
    grep -a "Max frequency for clock" "$dir/route.log" 2>/dev/null | tail -2
}

route base   out_ab_base
route outreg out_ab_outreg

echo
echo "=== A/B RESULT (seed $SEED, CRIT_DIST=1.0, y-base 40) -- $(date -Is) ==="
for d in out_ab_base out_ab_outreg; do
    printf "%-16s " "$(basename "$d")"
    grep -a "Max frequency for clock   'clk_h'" "$d/route.log" 2>/dev/null \
        | tail -1 | sed 's/.*clk_h.: //' || echo "(no result)"
done
