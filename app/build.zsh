#!/bin/zsh
# Builds app/dist/QL on Mac.app: one window that sets Quake Live up on its own Wine engine with
# glmt and starts it (app/README.md). Ad hoc signed, for this Mac. Starts nothing of Wine.
#
#   app/scripts/stage-components.zsh    first: my five files for the engine, built into app/prebuilt/
#   app/build.zsh                       the bundle
#   app/build.zsh --render [folder]     also every state of the window as PNGs (default
#                                       work/app-renders), nothing shown on screen
#
# In the bundle:
#   Contents/MacOS/QLonMac              the window (src/native), arm64
#   Contents/Frameworks/Sparkle.framework   app updates (pinned below; off without a feed)
#   Contents/Resources/qlom.zsh         the backend (src/qlom.zsh), common.zsh beside it
#   Contents/Resources/components/      winemac.so, win32u.so, libglmt.dylib, opengl32.so,
#                                       opengl32.dll and their STAMP (app/prebuilt/)
# The Wine engine is not in it: qlom.zsh downloads it at install time (Mach9, pinned in
# scripts/common.zsh). Steam and the game come from Valve.
#
# QL_ON_MAC_VERSION sets the version (0.1.0). QL_ON_MAC_FEED_URL with QL_ON_MAC_ED_PUBLIC_KEY turns
# updates on. QL_ON_MAC_NO_COMPONENTS=1 builds without app/prebuilt (for the render only: such an
# app cannot install).
set -euo pipefail
here="${0:A:h}"
repo="${here:h}"
cd "$here"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { print -u2 "this builds on an Apple Silicon Mac"; exit 1; }

VERSION=${QL_ON_MAC_VERSION:-0.1.0}
MACOS_MIN=$(plutil -extract LSMinimumSystemVersion raw src/Info.plist)
CACHE="$here/.cache"
APP="$here/dist/QL on Mac.app"
R="$APP/Contents/Resources"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Pinned: bump the version and the sha256 together (the same pin as GW2 on Mac's app).
SPARKLE_VERSION=2.10.0
SPARKLE_URL=https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
SPARKLE="$CACHE/sparkle-$SPARKLE_VERSION"
if [[ ! -d "$SPARKLE/Sparkle.framework" ]]; then
  mkdir -p "$CACHE"
  archive="$CACHE/Sparkle-$SPARKLE_VERSION.tar.xz"
  # GW2 on Mac's cache has the same file, if that project was built on this Mac
  for sibling in "$repo"/../gw2-on-mac/{app/,}.cache/$SPARKLE_SHA256/Sparkle-$SPARKLE_VERSION.tar.xz(N); do
    [[ -f "$archive" ]] || cp "$sibling" "$archive"
  done
  [[ -f "$archive" ]] || { print "downloading Sparkle $SPARKLE_VERSION"; curl -fL --retry 3 -o "$archive.part" "$SPARKLE_URL"; mv "$archive.part" "$archive"; }
  [[ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" == "$SPARKLE_SHA256" ]] || { print -u2 "Sparkle's archive is not the pinned one: $archive"; exit 1; }
  rm -rf "$SPARKLE.part"; mkdir -p "$SPARKLE.part"
  tar -xJf "$archive" -C "$SPARKLE.part"
  rm -rf "$SPARKLE"; mv "$SPARKLE.part" "$SPARKLE"
fi

P="$here/prebuilt"
PIECES=(winemac.so win32u.so libglmt.dylib opengl32.so opengl32.dll)
if [[ -z "${QL_ON_MAC_NO_COMPONENTS:-}" ]]; then
  [[ -f "$P/STAMP" ]] || { print -u2 "no app/prebuilt: run app/scripts/stage-components.zsh"; exit 1; }
  for f in $PIECES; do
    [[ "$(shasum -a 256 "$P/$f" 2>/dev/null | cut -d' ' -f1)" == "$(sed -n "s/  $f\$//p" "$P/STAMP")" ]] ||
      { print -u2 "app/prebuilt/$f is not the file its STAMP names: stage again"; exit 1; }
  done
fi

print "assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$R" "$APP/Contents/Frameworks"
sed -e "s/@VERSION@/$VERSION/g" src/Info.plist >"$APP/Contents/Info.plist"
if [[ -n "${QL_ON_MAC_FEED_URL:-}" ]]; then
  [[ -n "${QL_ON_MAC_ED_PUBLIC_KEY:-}" ]] || { print -u2 "QL_ON_MAC_FEED_URL needs QL_ON_MAC_ED_PUBLIC_KEY"; exit 1; }
  plutil -replace SUFeedURL -string "$QL_ON_MAC_FEED_URL" "$APP/Contents/Info.plist"
  plutil -replace SUPublicEDKey -string "$QL_ON_MAC_ED_PUBLIC_KEY" "$APP/Contents/Info.plist"
  plutil -replace SUEnableAutomaticChecks -bool YES "$APP/Contents/Info.plist"
fi
plutil -lint -s "$APP/Contents/Info.plist"
printf 'APPL????' >"$APP/Contents/PkgInfo"

swiftc -parse-as-library -O -target "arm64-apple-macos$MACOS_MIN" -F "$SPARKLE" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$APP/Contents/MacOS/QLonMac" src/native/*.swift
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"

install -m 755 src/qlom.zsh "$R/qlom.zsh"
install -m 644 "$repo/scripts/common.zsh" "$R/common.zsh"
if [[ -z "${QL_ON_MAC_NO_COMPONENTS:-}" ]]; then
  mkdir -p "$R/components"
  for f in $PIECES; do install -m 755 "$P/$f" "$R/components/$f"; done
  install -m 644 "$P/STAMP" "$R/components/STAMP"
fi
mkdir -p "$R/Licenses"
cp "$SPARKLE/LICENSE" "$R/Licenses/Sparkle-LICENSE.txt"
commit=$(git -C "$repo" rev-parse HEAD 2>/dev/null || print none)
[[ -z "$(git -C "$repo" status --porcelain 2>/dev/null)" ]] || commit="$commit with changes"
print -rl -- "app $VERSION" "commit $commit" "sparkle $SPARKLE_VERSION" >"$R/VERSIONS"

xattr -cr "$APP"
fw="$APP/Contents/Frameworks/Sparkle.framework"
for f in "$fw/Versions/B/Autoupdate" "$fw/Versions/B/Updater.app" "$fw"; do codesign --force --sign - "$f"; done
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
print "built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == --render ]]; then
  out="${2:-$repo/work/app-renders}"
  mkdir -p "$out"
  "$APP/Contents/MacOS/QLonMac" --render "$out"
fi
