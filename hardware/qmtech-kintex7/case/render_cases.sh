#!/bin/bash
# Regenerate the sealed and vented variants from the tall-xl file, then render
# every tray and lid STL.
#
# The three .scad files are ONE design: they are byte-identical apart from the
# two VARIANT_ lines. Keeping them as three real files (rather than one file
# plus include/) means each is self-contained and openable on its own, but it
# also means they can drift -- so tall-xl is the master and the other two are
# generated from it here, every time. Edit tall-xl only.
#
# This script was referenced by commit b205005 but never actually committed;
# without it the STLs in this directory cannot be reproduced by anyone else.
set -u
failed=0
CASE="$(cd "$(dirname "$0")" && pwd)"
OSC="${OPENSCAD:-/c/Program Files/OpenSCAD/openscad.exe}"
SRC="$CASE/v4-tall-xl/qmtech_xc7k325t_case_tall_xl.scad"

[ -x "$OSC" ] || { echo "openscad not found at $OSC -- set OPENSCAD=" >&2; exit 1; }

gen() { # dir file height vented comment [screen]
  out="$CASE/$1/$2"
  mkdir -p "$CASE/$1"
  scr="${6:-ili9341}"
  sed -e "s|^VARIANT_WALL_HEIGHT = .*|VARIANT_WALL_HEIGHT = $3;   // $5|" \
      -e "s|^VARIANT_VENTED       = .*|VARIANT_VENTED       = $4;  // $5|" \
      -e "s|^VARIANT_SCREEN       = .*|VARIANT_SCREEN       = \"$scr\";  // $5|" \
      "$SRC" > "$out"
  echo "  wrote $1/$2  (height $3, vented $4, screen $scr)"
}

echo "### regenerating variants from the tall-xl master"
# ONE TRAY, ONE LID, as of 2026-09-06.
#
# v4-sealed and v4-vented are gone. They were dead twice over: their lids were
# cut for the ILI9341 removed from the design on 2026-09-05, and their 24mm
# interior cannot contain the MEASURED 44mm heatsink+fan stack -- the clearance
# assert in the master refuses to build them, which is how this was noticed.
#
# The tray is rendered from v4-tall-xl and the lid from v4-cyd. Nothing is
# produced twice, so nothing can drift.
gen v4-cyd    qmtech_xc7k325t_case_cyd.scad    54 true  "CYD variant: lid for the ESP32 Cheap Yellow Display" cyd

echo
echo "### confirming the knobs actually differ"
grep -H "^VARIANT_" "$CASE"/v4-*/*.scad

echo
echo "### rendering"
# --render forces CGAL. Without it OpenSCAD exports the OpenCSG PREVIEW, which
# silently normalises away geometry past ~100k elements -- that is how a lid
# came out a fraction of its real size once the vent grid was added.
for d in v4-tall-xl v4-cyd; do
  f=$(ls "$CASE/$d"/*.scad)
  # tray-only and lid-only copies: the master emits both side by side
  sed -e '/^translate(\[0, outer_width + 15, 0\])$/d' -e '/^    lid();$/d' "$f" > "$CASE/$d/_tray.scad"
  sed -e '/^base_tray();$/d' -e '/^translate(\[0, outer_width + 15, 0\])$/d' "$f" > "$CASE/$d/_lid.scad"
  # v4-tall-xl supplies the TRAY, v4-cyd the LID. Rendering tall-xl's own lid
  # as well would produce a second copy of the same CYD lid now that the
  # ILI9341 is gone -- two identical files, free to drift apart.
  parts="tray"; [ "$d" = "v4-cyd" ] && parts="lid"
  for part in $parts; do
    tgt="base_tray.stl"; [ "$part" = "lid" ] && tgt="lid.stl"
    echo "-- $d/$tgt"
    # EXIT CODE, NOT JUST OUTPUT. Piping openscad through grep replaces its
    # status with grep's, so a failed render -- an assert, a CGAL error --
    # reported success and left the PREVIOUS STL in place, looking freshly
    # built. That happened on 2026-09-06: the measured 44mm heatsink+fan
    # stack made the 24mm-walled variants impossible, the assert fired
    # correctly, and this script still exited 0 with stale meshes on disk.
    if ! ( set -o pipefail
           cd "$CASE/$d" && "$OSC" --render -o "$tgt" "_$part.scad" 2>&1 \
             | grep -viE "^$|DEPRECATED" | head -12 ); then
      echo "   ^^ FAILED -- $d/$tgt NOT regenerated; the file on disk is stale"
      failed=1
    fi
  done
  rm -f "$CASE/$d/_tray.scad" "$CASE/$d/_lid.scad"
done

# Previews are opt-in: they are full CGAL renders too, so they roughly double
# the runtime, and they are documentation rather than something you print.
#   ./render_cases.sh --previews
# --render is REQUIRED here, not just tidy. The honeycomb exceeds OpenCSG's
# preview normalisation limit, so preview-mode renders of the lid came out
# BLANK while the STLs beside them were perfectly good.
if [ "$failed" != 0 ]; then
  echo
  echo "### ONE OR MORE RENDERS FAILED -- see above. Stale STLs remain."
  exit 1
fi

if [ "${1:-}" = "--previews" ]; then
  echo
  echo "### previews"
  for d in v4-tall-xl v4-cyd; do
    f=$(ls "$CASE/$d"/*.scad)
    echo "-- $d/preview_isometric.png"
    ( cd "$CASE/$d" && "$OSC" --render --autocenter --viewall         --imgsize=1200,900 --camera=0,0,0,55,0,25,0         -o preview_isometric.png "$(basename "$f")" 2>&1         | grep -viE "^$|DEPRECATED|ECHO" | head -4 )
  done
fi

echo
echo "### resulting STLs"
ls -l "$CASE"/v4-*/*.stl | awk '{print $5, $9}'
