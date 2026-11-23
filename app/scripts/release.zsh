#!/bin/zsh
# Signs, notarizes and packages the app in app/dist (app/build.zsh first, with the feed) and builds
# its update feed for Sparkle. GW2 on Mac's release script, cut down to one kind of release.
#
#   app/release/<version>/QL on Mac.app             Developer ID, hardened runtime
#   app/release/<version>/QL-on-Mac-<version>.dmg   signed, notarized, stapled
#   app/release/<version>/appcast.xml               the feed, with this version only
#
#   app/scripts/release.zsh --sign-only     sign and verify, nothing else
#   app/scripts/release.zsh --no-notarize   sign, package and build the feed; nothing goes to Apple
#   app/scripts/release.zsh                 sign, package, notarize, staple, build and check the feed
#   app/scripts/release.zsh --draft         the same, then a draft GitHub release v<version> with the
#                                           DMG and appcast.xml, its tag on HEAD. It stops unless
#                                           QL_ON_MAC_PUBLISH=1.
# Publishing the draft makes the update live: the app reads
# https://github.com/jdrly/ql-on-mac/releases/latest/download/appcast.xml.
#
# A release build has the feed in it:
#   QL_ON_MAC_FEED_URL=https://github.com/jdrly/ql-on-mac/releases/latest/download/appcast.xml \
#   QL_ON_MAC_ED_PUBLIC_KEY=<generate_keys -p> app/build.zsh
#
# One notarization: submitting the disk image notarizes the app inside it too, and the ticket is
# stapled to the DMG.
#
# Needs a Developer ID Application identity in the keychain (IDENTITY names one, else the first one
# found), NOTARY_PROFILE (a notarytool keychain profile, from xcrun notarytool store-credentials),
# Sparkle's EdDSA key in the login keychain (Sparkle's generate_keys; build.zsh unpacks the tools
# into app/.cache), gh logged in for --draft, and release notes in app/release-notes/<version>.md.
# They go into the feed and the GitHub release.
#
# The engine's files in Resources/components get my signature here, like every Mach-O file of a
# notarized app. That changes their bytes, so they no longer match the sha256 in their STAMP. The
# backend compares the STAMP file only, and signs each file ad hoc again when it goes into the
# engine.
set -euo pipefail
here="${0:A:h:h}"
repo="${here:h}"
cd "$here"
MODE="${1:-}"
case "$MODE" in ""|--sign-only|--no-notarize|--draft) ;; *) print -u2 "unknown option: $MODE"; exit 2 ;; esac
(( $# <= 1 )) || { print -u2 "one option at most"; exit 2; }
[[ "$MODE" != --draft || "${QL_ON_MAC_PUBLISH:-}" == 1 ]] ||
  { print -u2 "--draft creates a GitHub release. Set QL_ON_MAC_PUBLISH=1 to do that."; exit 1; }
[[ "$(uname -s)" == Darwin ]] || { print -u2 "this runs on a Mac"; exit 1; }
fail() { print -u2 -r -- "$*"; exit 1; }
say() { print -r -- "[release] $*"; }

REPO=jdrly/ql-on-mac
APP_NAME="QL on Mac"
DASHED="${APP_NAME// /-}"
SRC="dist/$APP_NAME.app"
[[ -d "$SRC" ]] || fail "no $SRC: run app/build.zsh"
plist="$SRC/Contents/Info.plist"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$plist")
OUT="release/$VERSION"
APP="$OUT/$APP_NAME.app"
DMG="$OUT/$DASHED-$VERSION.dmg"
NOTES="release-notes/$VERSION.md"
URL_PREFIX="https://github.com/$REPO/releases/download/v$VERSION/"
SPARKLE_BIN="$here/.cache/sparkle-$(sed -n 's/^SPARKLE_VERSION=//p' build.zsh)/bin"
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
[[ -n "$IDENTITY" ]] || fail "no Developer ID Application identity in the keychain"
MACHO=(winemac.so win32u.so libglmt.dylib opengl32.so)

[[ -f "$SRC/Contents/Resources/components/STAMP" ]] || fail "the app in dist has no components (a render-only build)"
built=$(sed -n 's/^commit //p' "$SRC/Contents/Resources/VERSIONS")
if [[ "$MODE" != --sign-only ]]; then
  key=$(plutil -extract SUPublicEDKey raw "$plist" 2>/dev/null || true)
  [[ -n "$key" && -n "$(plutil -extract SUFeedURL raw "$plist" 2>/dev/null || true)" ]] ||
    fail "updates are off in this build: build with QL_ON_MAC_FEED_URL and QL_ON_MAC_ED_PUBLIC_KEY, or use --sign-only"
  [[ -x "$SPARKLE_BIN/generate_appcast" ]] || fail "no $SPARKLE_BIN: run app/build.zsh"
  # the key the app trusts must be the public half of the key the feed is signed with
  mine=$("$SPARKLE_BIN/generate_keys" -p)
  [[ "$mine" == "$key" ]] || fail "the app's SUPublicEDKey is not the keychain's Sparkle key ($mine)"
  [[ -f "$NOTES" ]] || fail "no release notes: app/$NOTES"
fi
if [[ -z "$MODE" || "$MODE" == --draft ]]; then
  [[ -n "${NOTARY_PROFILE:-}" ]] || fail "NOTARY_PROFILE is not set (a notarytool keychain profile)"
  [[ "$built" != *"with changes"* ]] || fail "the app in dist was built from a checkout with changes: commit, then app/build.zsh again"
fi
if [[ "$MODE" == --draft ]]; then
  gh auth status >/dev/null 2>&1 || fail "gh is not logged in"
  ! gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1 || fail "release v$VERSION already exists"
  head=$(git -C "$repo" rev-parse HEAD)
  [[ "$built" == "$head" && -z "$(git -C "$repo" status --porcelain)" ]] ||
    fail "the app in dist was not built from HEAD $head as committed (its VERSIONS: $built)"
  git -C "$repo" fetch -q origin main
  git -C "$repo" merge-base --is-ancestor "$head" origin/main || fail "$head is not on origin/main: push it first"
  [[ "$(git -C "$repo" remote get-url origin)" == *"$REPO"* ]] || fail "origin is not $REPO: the tag would name a commit that repository does not have"
  if tag=$(gh api "repos/$REPO/git/ref/tags/v$VERSION" 2>&1); then fail "tag v$VERSION already exists"
  elif [[ "$tag" != *"HTTP 404"* ]]; then fail "could not ask GitHub for the tag v$VERSION: $tag"; fi
fi

sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }

# Submits $1 and asks Apple until it is processed (through network errors, up to an hour);
# prints Apple's log and fails unless it was accepted.
notarize() {
  local id state="" deadline=$(( SECONDS + 3600 ))
  id=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --output-format json | plutil -extract id raw -)
  print -r -- "  submission $id"
  while (( SECONDS < deadline )); do
    state=$(xcrun notarytool info "$id" --keychain-profile "$NOTARY_PROFILE" --output-format json 2>/dev/null |
      plutil -extract status raw - 2>/dev/null || true)
    case "$state" in Accepted|Invalid|Rejected) break ;; esac
    sleep 20
  done
  print -r -- "  status: ${state:-unknown}"
  [[ "$state" == Accepted ]] || { xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true; exit 1; }
}

say "$VERSION: copying the app"
rm -rf "$OUT"
mkdir -p "$OUT"
ditto "$SRC" "$APP"
xattr -cr "$APP"

# Inside out: the engine's files, Sparkle in its documented order (Autoupdate, Updater.app, the
# framework; build.zsh removed its XPC services), then the app. opengl32.dll is a Windows file and
# gets no signature of its own.
say "signing as $IDENTITY"
for f in $MACHO; do sign "$APP/Contents/Resources/components/$f"; done
fw="$APP/Contents/Frameworks/Sparkle.framework"
sign "$fw/Versions/B/Autoupdate"
sign "$fw/Versions/B/Updater.app"
sign "$fw"
sign --entitlements "$here/src/entitlements.plist" "$APP"
codesign --verify --strict --deep "$APP"
say "signature verified: $(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application.*\)/\1/p')"
[[ "$MODE" != --sign-only ]] || exit 0

say "building the disk image"
stage="$OUT/dmg"
mkdir -p "$stage"
ditto "$APP" "$stage/$APP_NAME.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "$APP_NAME $VERSION" -srcfolder "$stage" -fs HFS+ -format ULMO "$DMG"
rm -rf "$stage"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
if [[ "$MODE" == --no-notarize ]]; then
  say "not notarized (--no-notarize)"
else
  say "notarizing the disk image"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  spctl --assess --type execute --verbose=2 "$APP"
fi

# The feed: one item, this version, the notes inside it. generate_appcast signs the DMG with the
# keychain's EdDSA key. It runs on a folder of its own, so that it finds this DMG and nothing else.
say "building the update feed"
feed="$OUT/feed"
rm -rf "$feed"
mkdir -p "$feed"
cp -c "$DMG" "$feed/"
cp "$NOTES" "$feed/$DASHED-$VERSION.md"
"$SPARKLE_BIN/generate_appcast" --maximum-versions 1 --embed-release-notes --download-url-prefix "$URL_PREFIX" "$feed"
cp "$feed/appcast.xml" "$OUT/appcast.xml"
rm -rf "$feed"
xmllint --noout "$OUT/appcast.xml"
# as Sparkle will: the length and the EdDSA signature against the app's public key
say "checking the update feed"
swift "$here/scripts/check-appcast.swift" "$OUT/appcast.xml" "$OUT" "$key"
grep -q "url=\"$URL_PREFIX${DMG:t}\"" "$OUT/appcast.xml" || fail "the feed does not point at $URL_PREFIX${DMG:t}"

if [[ "$MODE" != --draft ]]; then
  say "$DMG ($(du -h "$DMG" | cut -f1)) and $OUT/appcast.xml; no GitHub release"
  exit 0
fi
say "creating the draft GitHub release v$VERSION on $head"
gh release create "v$VERSION" --repo "$REPO" --draft --target "$head" --title "$APP_NAME $VERSION" \
  --notes-file "$NOTES" "$DMG" "$OUT/appcast.xml"
say "draft v$VERSION created with $DMG ($(du -h "$DMG" | cut -f1)) and the feed; publishing it makes the update live"
