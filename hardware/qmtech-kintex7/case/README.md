# QMTECH XC7K325T dev board -- 3D-printable case (v4, fully enclosed)

A two-part case (base tray + closed lid) for the
[QMTECH XC7K325T dev board](../README.md), sized from the vendor's own
real ECAD dimension export. Parametric OpenSCAD, FDM-print friendly (no
supports needed).

## v4: complete box, no open-top chimney

v3 put the FPGA's real heatsink (Ohmite/Arcol BGAH270-175E, 17.5mm) under
a raised, **open-top** chimney -- short walls everywhere else, tall vented
stack just over the chip, no roof over it. That's wrong for an enclosure
that has to actually close: an open top is dust/finger/liquid exposure
over exposed FPGA pins and a heatsink, not a "case". **v4 replaces it with
a genuinely closed box**: uniform wall height, sized so the *entire*
interior clears the heatsink everywhere, roof intact on all sides. Where
airflow matters, venting is a grid of small drilled holes through the
still-solid lid -- a perforated panel, never a bore straight through to
open air.

The CM4-cutout fix from v3 stays (it's a low-profile mezzanine, doesn't
need a panel opening -- see below), and so does the square-corners fix
from v1 (hull()-rounded corners silently broke CGAL cutout subtraction).

## Three variants

All three share one template (`VARIANT_WALL_HEIGHT` / `VARIANT_VENTED`
knobs at the top of each `.scad`) and differ only in those two numbers.
Pick whichever fits your cooling plan; all three fully enclose the real
heatsink with positive clearance margin (each file `echo()`s the exact
number when rendered).

| Variant | Dir | Wall height | Venting | Heatsink margin | Use when |
|---|---|---|---|---|---|
| **Sealed** | `v4-sealed/` | 24mm | none, fully solid | 3.9mm | passive cooling is enough, or you want a dust/splash-resistant box |
| **Vented** | `v4-vented/` | 24mm | 5x5 grid of 3mm holes over the FPGA | 3.9mm | same size as Sealed, adds passive convection through the perforated lid |
| **Tall-XL** | `v4-tall-xl/` | 36mm | same 5x5 vent grid | 15.9mm | bigger/aftermarket heatsink, or a fan sits in the extra headroom above the stock one |

![Sealed, isometric](v4-sealed/preview_isometric.png)
![Vented, isometric](v4-vented/preview_isometric.png)
![Tall-XL, isometric](v4-tall-xl/preview_isometric.png)

Each directory is self-contained:
- `qmtech_xc7k325t_case_<variant>.scad` -- parametric source for that variant
- `base_tray.stl` / `lid.stl` -- exported meshes, ready to slice separately
- `preview_isometric.png` -- render showing tray (open, left) + lid (right)

Regenerate any of them:
```sh
openscad -o base_tray.stl qmtech_xc7k325t_case_<variant>.scad   # comment out lid() first
openscad -o lid.stl qmtech_xc7k325t_case_<variant>.scad          # comment out base_tray() first
```
Or export both parts side-by-side as-is (the file already offsets them
apart for a shared plate). Requires OpenSCAD 2021.01+, no other
dependencies.

To make a 4th variant of your own: copy any of the three `.scad` files,
change `VARIANT_WALL_HEIGHT`/`VARIANT_VENTED` at the top, re-render. All
downstream geometry (chimney math is gone; wall height now feeds
`heatsink_margin_mm` directly) recomputes from those two numbers.

## Heatsink: BGAH270-175E on AliExpress

Searched AliExpress specifically for the **Ohmite/Arcol BGAH270-175E**
(the exact part these dimensions are drawn from). **Not listed there** --
it's a distributor-only part (RS Components, DigiKey, Mouser, Farnell,
Enrgtech). AliExpress alternatives found in the same class/size
(27x27mm BGA footprint, passive extruded/finned aluminum) but **not
individually verified for exact height or thermal specs** since
AliExpress product pages are blocked from this environment's network
egress -- only search-result snippets were visible, not full listings:

- "WE DO HEATSINK Store" storefront -- carries assorted BGA/FPGA
  heatsinks in this size class.
- Generic "BGA heatsink 27x27mm" category listings -- multiple sellers,
  varying heights (12-25mm typical for this footprint).
- A "Mister FPGA - Heat Sink" listing -- sized for the MiSTer FPGA
  community's own Cyclone V boards, same rough footprint class.

None of these are a confirmed drop-in match for BGAH270-175E's exact
27x27x17.5mm envelope -- **measure before committing to a case variant**.
If your actual heatsink is taller than 17.5mm, use Tall-XL and check the
`heatsink_margin_mm` echo after updating `heatsink_lwh_mm` in the .scad.
Distributor-sourced equivalents in the same class also exist (e.g.
Fischer Elektronik ICK BGA 27x27 series, AAVID/Boyd Thermalloy 27x27x18mm)
if you'd rather buy the real thing than gamble on an unverified AliExpress
listing.

## Design decisions (read before printing)

1. **Hole/cutout positions are still estimates.** Sourced from the QMTECH
   manual's Figure 2-1 (160x90mm board outline) and cover-page photo, plus
   [ChinaQMTECH/QMTECH_Kintex-7_Development_Board](https://github.com/ChinaQMTECH/QMTECH_Kintex-7_Development_Board)'s
   real Allegro ECAD dimension export
   (`hardware/Dimension(Board_Top_View).pdf`) for the FPGA position and
   general header/DC-jack/switch layout -- not exact vector coordinates
   for every feature. Every cutout is deliberately oversized
   (`cutout_margin`) to absorb that. Adjust `lid_top_cutouts_mm`,
   `dc_jack_center_mm`, `heatsink_center_mm`, `sensor_hole_center_mm`, or
   `display_center_mm` and re-render if something doesn't line up once
   you have the board.
2. **No CM4 cutout.** The CM4 mates over two low-profile 100-pin
   board-to-board connectors (1.5mm or 3.0mm stack height per the
   [Raspberry Pi CM4 datasheet](https://datasheets.raspberrypi.com/cm4/cm4-datasheet.pdf)),
   module itself 4.7mm thick -- **total ~6.2-7.7mm above the carrier
   board.** Fully internal, low-profile mezzanine; its HDMI/USB/
   Ethernet/etc. are already broken out to *this* board's own edge
   connectors (`left_edge_cutouts()` handles those). No panel opening
   needed.
3. **Heatsink math is traceable, not a magic number.**
   `heatsink_total_clearance_mm` is the BGAH270-175E's real 17.5mm height
   plus a chip/thermal-pad allowance and an assembly margin.
   `heatsink_margin_mm = (wall_height + lid_thickness) -
   heatsink_total_clearance_mm` -- printed via `echo()` on every render,
   so you can see immediately whether a given wall height still clears a
   different heatsink after editing `heatsink_lwh_mm`.
4. **Venting, if enabled, is a perforated panel, not an opening.**
   `VARIANT_VENTED` drills a grid of 3mm holes through the *solid* lid
   over the FPGA's footprint -- convection through small holes, not an
   exposed bore. `VARIANT_VENTED = false` leaves that area fully solid.
5. **Display and sensor part numbers are borrowed from a different
   board, not verified against this one.** The KMRTM28028-SPI (2.8"
   ILI9341+XPT2046) and DS18B20 are what
   [odo-miner-cyclonev](https://github.com/colneech-dev/odo-miner-cyclonev)
   uses and verified on real hardware -- a different Cyclone V SoC board,
   not this Kintex-7 one. **No RTL or driver software for either exists
   anywhere in this repo** -- this case only adds the physical mounting.
   Wiring a display needs more signal lines (CS/DC/RST/SCLK/MOSI/MISO +
   touch CS/IRQ) than the 4 spare CM4 GPIO lines
   (`hdl/odocrypt_gpio_wrapper.v` uses GPIO0-23) provide, so the realistic
   path is the board's 50-pin extension header (JP5) -- not attempted
   here.
6. **Board retention and standoffs**: a perimeter lip is the primary
   retention (works regardless of where the real mounting holes are), 4
   corner standoffs are a secondary generic-default fixation, not
   transcribed with confidence from any dimension drawing.
7. **Lid attachment**: a friction-fit alignment skirt seats inside the
   tray's top opening, secured by 4 corner screws (M3 self-tap or
   heat-set insert) into full-height bosses, separate from the shorter
   board-support standoffs.
8. **Square corners.** `hull()`-based rounding previously produced CGAL
   boolean geometry where cutout subtraction silently didn't intersect --
   confirmed by A/B vertex-count testing back in v1. These files never
   use rounding.
9. **Bugs caught and fixed during development** (all verified
   numerically -- vertex/facet/Volumes counts from `--render -o file.stl`
   -- not just visually):
   - v2: a fusion bug (lid skirt / display standoffs touching the lid
     panel at an exact coincident Z-plane instead of genuinely
     overlapping) -- fixed with `fuse_eps` overlaps.
   - v2: a layout bug -- the first draft's flat ventilation grille and
     sensor hole overlapped the (now-removed) CM4 cutout's footprint.
   - v3: repositioning the display after removing the CM4 cutout and
     adding the (now also removed) chimney required re-deriving free
     space from scratch, done with explicit coordinate range checks.
   - v4: confirmed the vent-hole grid actually cuts material (Vented
     variant: 3072 vertices vs Sealed's 1920, i.e. the holes are real
     geometry, not a no-op) and that `heatsink_margin_mm` stays positive
     for both wall heights (Sealed/Vented: 3.9mm; Tall-XL: 15.9mm).
10. **Print a fit-check first** -- these are estimates, better-sourced
    than v1/v2 but still estimates.

## Print settings

0.2mm layers, 15-20% infill, no supports (everything overhangs at 90° from
a flat base or less on both parts). PETG or ABS given there's an actual
heatsink in the design -- PLA's ~55-60°C heat deflection is a real concern
this close to one, especially in the Sealed variant with no venting.

## History

- **v1**: open-top tray, no lid.
- **v2**: two-part (tray + lid), added connector cutouts, screen/sensor
  mounts, a CM4 panel cutout, and an unsourced flat 28mm wall height.
- **v3**: removed the unnecessary CM4 cutout, replaced the guessed wall
  height with a real heatsink part (BGAH270-175E) driving a short case +
  raised open-top vented chimney over the FPGA.
- **v4 (current)**: replaced the open-top chimney with a genuinely closed
  box -- uniform height sized to clear the heatsink everywhere, optional
  venting via a perforated lid panel instead of an opening. Three
  variants (Sealed / Vented / Tall-XL) instead of one fixed geometry.
