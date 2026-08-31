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
gen v4-sealed qmtech_xc7k325t_case_sealed.scad 24 false "SEALED variant: fully solid lid, no venting"
gen v4-vented qmtech_xc7k325t_case_vented.scad 24 true  "VENTED variant: perforated lid panel over the FPGA"
# CYD lid: same tray and wall height as tall-xl -- only the lid aperture
# differs, so only lid.stl is rendered for it below.
gen v4-cyd    qmtech_xc7k325t_case_cyd.scad    48 true  "CYD variant: lid for the ESP32 Cheap Yellow Display" cyd

echo
echo "### confirming the knobs actually differ"
grep -H "^VARIANT_" "$CASE"/v4-*/*.scad

echo
echo "### rendering"
# --render forces CGAL. Without it OpenSCAD exports the OpenCSG PREVIEW, which
# silently normalises away geometry past ~100k elements -- that is how a lid
# came out a fraction of its real size once the vent grid was added.
for d in v4-sealed v4-vented v4-tall-xl v4-cyd; do
  f=$(ls "$CASE/$d"/*.scad)
  # tray-only and lid-only copies: the master emits both side by side
  sed -e '/^translate(\[0, outer_width + 15, 0\])$/d' -e '/^    lid();$/d' "$f" > "$CASE/$d/_tray.scad"
  sed -e '/^base_tray();$/d' -e '/^translate(\[0, outer_width + 15, 0\])$/d' "$f" > "$CASE/$d/_lid.scad"
  # v4-cyd is a LID ONLY: its tray is byte-identical to tall-xl's, and a
  # duplicate would only invite the two drifting apart.
  parts="tray lid"; [ "$d" = "v4-cyd" ] && parts="lid"
  for part in $parts; do
    tgt="base_tray.stl"; [ "$part" = "lid" ] && tgt="lid.stl"
    echo "-- $d/$tgt"
    ( cd "$CASE/$d" && "$OSC" --render -o "$tgt" "_$part.scad" 2>&1 \
        | grep -viE "^$|DEPRECATED" | head -8 )
  done
  rm -f "$CASE/$d/_tray.scad" "$CASE/$d/_lid.scad"
done

# Previews are opt-in: they are full CGAL renders too, so they roughly double
# the runtime, and they are documentation rather than something you print.
#   ./render_cases.sh --previews
# --render is REQUIRED here, not just tidy. The honeycomb exceeds OpenCSG's
# preview normalisation limit, so preview-mode renders of the lid came out
# BLANK while the STLs beside them were perfectly good.
if [ "${1:-}" = "--previews" ]; then
  echo
  echo "### previews"
  for d in v4-sealed v4-vented v4-tall-xl; do
    f=$(ls "$CASE/$d"/*.scad)
    echo "-- $d/preview_isometric.png"
    ( cd "$CASE/$d" && "$OSC" --render --autocenter --viewall         --imgsize=1200,900 --camera=0,0,0,55,0,25,0         -o preview_isometric.png "$(basename "$f")" 2>&1         | grep -viE "^$|DEPRECATED|ECHO" | head -4 )
  done
fi

echo
echo "### resulting STLs"
ls -l "$CASE"/v4-*/*.stl | awk '{print $5, $9}'
