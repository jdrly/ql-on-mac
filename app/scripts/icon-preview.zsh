#!/bin/zsh
# Renders the app icon (src/AppIcon.icon, an Icon Composer document) with Icon Composer's own
# tool, so the pictures show what macOS will draw: the six appearances at 512 px, and the default
# one at the small sizes. Nothing is shown on screen.
#
#   app/scripts/icon-preview.zsh [folder]     default: work/app-icon
#
# The mark is my own drawing: a ring and a spike that make a Q, in red and white on near black.
# It is not id Software's Quake emblem, and must not become a copy of it.
set -euo pipefail
here="${0:A:h}"
doc="${here:h}/src/AppIcon.icon"
out="${1:-${here:h:h}/work/app-icon}"
ictool="${ICTOOL:-/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool}"
[[ -x "$ictool" ]] || { print -u2 "no ictool at $ictool (it comes with Xcode's Icon Composer)"; exit 1; }
mkdir -p "$out"
for rendition in Default Dark TintedLight TintedDark ClearLight ClearDark; do
  "$ictool" "$doc" --export-image --output-file "$out/$rendition-512.png" --platform macOS --rendition $rendition \
    --width 512 --height 512 --scale 1 >/dev/null
done
for px in 128 64 32 16; do
  "$ictool" "$doc" --export-image --output-file "$out/Default-$px.png" --platform macOS --rendition Default \
    --width $px --height $px --scale 1 >/dev/null
done
print "rendered into $out"
