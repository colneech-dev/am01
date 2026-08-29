# odo-ui assets

`odo-ui` is built from the sibling odo-miner-cyclonev checkout and looks for
these at fixed paths; without them it starts but renders nothing legible:

    /etc/odo-ui/fonts/IBMPlexMono-Medium.ttf
    /etc/odo-ui/fonts/SpaceGrotesk-SemiBold.ttf
    /etc/odo-ui/bg.png                          (optional 320x240 background)

They are NOT in either repo -- `sw/odo-ui/fetch-assets.sh` downloads them, and
both URLs in that script now 404 because the upstream layouts moved. The files
here came from the Google Fonts mirror instead:

    ofl/ibmplexmono/IBMPlexMono-Medium.ttf
    ofl/spacegrotesk/SpaceGrotesk[wght].ttf

Both SIL OFL 1.1 (see OFL.txt), which permits redistribution, so they are
committed here rather than fetched at build time -- a build that reaches out to
GitHub is a build that breaks when a path moves, which is exactly what happened.

CAVEAT: Space Grotesk is only published as a VARIABLE font now. The file named
SpaceGrotesk-SemiBold.ttf is really SpaceGrotesk[wght].ttf, and stb_truetype
renders a variable font's default instance -- so it draws at the default weight,
not SemiBold. Cosmetic only.
