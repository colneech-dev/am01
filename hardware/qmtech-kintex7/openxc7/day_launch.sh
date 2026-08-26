#!/usr/bin/env bash
# Launch the day's two experiment slots.
#
# WHY THIS IS A FILE AND NOT AN INLINE COMMAND
# --------------------------------------------
# The first attempt passed specs inline through `wsl -e bash -lc "..."` and used
# "$J\_vfpms.json". Bash parses that as the variable $J_vfpms (undefined), not
# $J followed by "_vfpms", so every spec got an empty netlist path, run_cfg.sh
# bailed on a missing file, and both chains reported "slot complete" having run
# nothing. Quoting through the wsl wrapper has caused several failures in this
# project; a script file has no such layer.
#
# Two slots run concurrently. Memory allows two nextpnr processes (~3.5 GB peak
# each against 11 GB); three took free memory to 2 GB with an OOM kill already
# on record here.
#
# Slot A waits for vfp_cde15, which is still running. Slot B starts immediately.
set -euo pipefail

cd /mnt/c/Users/Colin/Documents/GitHub/am01/hardware/qmtech-kintex7/openxc7
J=out_nm1_nosr/am01_qmtech_top

# Slot A -- floorplan geometry, and CRIT_DIST below 1.0
nohup setsid bash day_chain.sh vfp_cde15 \
  "vfpmid_cde|${J}_vfpmid.json|NEXTPNR_CRIT_DIST_EXP=1.0" \
  "vfpstr_cde|${J}_vfpstr.json|NEXTPNR_CRIT_DIST_EXP=1.0" \
  "vfp_cde075|${J}_vfp.json|NEXTPNR_CRIT_DIST_EXP=0.75" \
  "vfp_cde_hp|${J}_vfp.json|NEXTPNR_CRIT_DIST_EXP=1.0,NEXTPNR_HPWL_SCALE_FIX=1" \
  > day_slotA.log 2>&1 < /dev/null &

sleep 2

# Slot B -- combined geometry, wider columns, and the knobs previously refuted
# for destroying routability (which the floorplan now supplies)
nohup setsid bash day_chain.sh - \
  "vfpms_cde|${J}_vfpms.json|NEXTPNR_CRIT_DIST_EXP=1.0" \
  "vfp4_cde|${J}_vfp4.json|NEXTPNR_CRIT_DIST_EXP=1.0" \
  "vfp_cde_wd|${J}_vfp.json|NEXTPNR_CRIT_DIST_EXP=1.0,NEXTPNR_WIRE_DEMAND=1.0" \
  "vfp_cde_sb|${J}_vfp.json|NEXTPNR_CRIT_DIST_EXP=1.0,NEXTPNR_SMALL_BETA=0.4" \
  > day_slotB.log 2>&1 < /dev/null &

sleep 20
echo "nextpnr procs: $(ps aux | grep -c '[n]extpnr-xilinx')"
ps aux | grep '[n]extpnr-xilinx' | grep -oE 'placed_[a-z0-9_]+' || true
echo "--- slot A ---"; head -1 day_slotA.log
echo "--- slot B ---"; head -2 day_slotB.log
