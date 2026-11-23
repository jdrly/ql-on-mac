#!/bin/zsh
# Install Windows Steam into the bottle with Valve's installer, silently. This starts Wine and ends
# the session again; Steam itself is first started by scripts/ql.zsh steam, where I log in and
# install Quake Live.
#
#   scripts/install-steam.zsh
set -euo pipefail
source "${0:A:h}/common.zsh"
mac_only
need_engine
need_bottle
bottle_running && die "a Wine session of the bottle runs: end it first (scripts/ql.zsh stop)"

if [[ -f "$STEAM_DIR/steam.exe" ]]; then
  say "Steam is installed in the bottle"
  exit 0
fi
setup="$DOWNLOADS/SteamSetup.exe"
mkdir -p "$DOWNLOADS" "$LOGS"
[[ -s "$setup" ]] || { say "downloading SteamSetup.exe from Valve"; curl -fL --retry 3 -o "$setup.part" "$STEAM_SETUP_URL"; mv -f "$setup.part" "$setup"; }
say "installing Steam (Valve's installer, silently)"
wine_cmd "$setup" /S >>"$LOGS/setup.log" 2>&1 || { wine_stop; die "Valve's installer failed: $LOGS/setup.log"; }
wine_wait
[[ -f "$STEAM_DIR/steam.exe" ]] || die "the installer ended without installing Steam: $LOGS/setup.log"
say "Steam is installed in the bottle"
