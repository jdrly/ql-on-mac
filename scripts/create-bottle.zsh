#!/bin/zsh
# Create the bottle (work/bottle) with the engine and set what Quake Live needs in it. This starts
# Wine (wineboot, about a minute, no window of the game or Steam) and ends the session again.
#
#   scripts/create-bottle.zsh
set -euo pipefail
source "${0:A:h}/common.zsh"
mac_only
need_engine
bottle_running && die "a Wine session of the bottle runs: end it first (scripts/ql.zsh stop)"

if [[ ! -f "$BOTTLE/system.reg" ]]; then
  say "creating the bottle (wineboot, about a minute)"
  mkdir -p "$BOTTLE" "$LOGS"
  wine_cmd wineboot --init >>"$LOGS/setup.log" 2>&1 || { wine_stop; die "wineboot failed: $LOGS/setup.log"; }
  wine_wait
  [[ -f "$BOTTLE/user.reg" ]] || die "Wine did not create the bottle: $LOGS/setup.log"
else
  say "the bottle is there (Steam and the game in it are kept)"
fi

# Retina mode: the game sees the display's real pixels (3840x2160 on the 4K display), and glmt
# renders at the window's physical size. Wine reads it when a session starts.
say "bottle settings: Retina mode on"
wine_cmd reg add 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /d y /f >>"$LOGS/setup.log" 2>&1
wine_cmd reg add 'HKCU\Software\Wine\WineDbg' /v ShowCrashDialog /t REG_DWORD /d 0 /f >>"$LOGS/setup.log" 2>&1
wine_stop
print -r -- "$ENGINE_NAME" >"$BOTTLE/.ql-bottle"
