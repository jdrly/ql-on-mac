#!/bin/zsh
# Runs app/src/qlom.zsh from start to end in a sandbox, on any machine: a stand-in engine whose
# "wine" only pretends (it writes down what it was asked and makes the files a real run would
# leave), a stand-in SteamSetup.exe, stand-in components. Nothing of a real install is touched
# and no real Wine starts.
#
#   app/scripts/test-backend.zsh [folder]      default: work/app-sandbox/test
#
# Not covered here: what needs a running session to be seen (a real wineserver's process), the
# Mac's own tools (codesign, the display's size) and the window.
set -euo pipefail
repo="${0:A:h:h:h}"
box="${1:-$repo/work/app-sandbox/test}"
[[ "$box" == /* ]] || box="$PWD/$box"
rm -rf "$box"
mkdir -p "$box/res" "$box/make/wine/bin" "$box/make/wine/lib/wine/aarch64-unix" "$box/make/wine/lib/wine/i386-windows"

# the backend as the bundle has it: qlom.zsh and common.zsh side by side, components beside them
cp "$repo/app/src/qlom.zsh" "$repo/scripts/common.zsh" "$box/res/"
mkdir -p "$box/res/components"
for f in win32u.so libglmt.dylib opengl32.so opengl32.dll; do print -r -- "mine $f" >"$box/res/components/$f"; done
print -r -- "mine winemac.so libglmt.dylib" >"$box/res/components/winemac.so"
print -r -- "test-1" >"$box/res/components/STAMP"

# the stand-in engine
cat >"$box/make/wine/bin/wine" <<'WINE'
#!/bin/sh
# pretends: writes the call down, leaves the files a real run would
echo "$(env | grep -E '^(GLMT_PRESENT|WINE_GLMT_BATCH|WINE_GLMT_FULLSCREEN_SPACE|WINEMSYNC)=' | sort | tr '\n' ' ')| $*" >>"$WINEPREFIX/../calls.log"
case "$1" in
  wineboot) : >"$WINEPREFIX/system.reg"; : >"$WINEPREFIX/user.reg" ;;
  reg) echo "$*" >>"$WINEPREFIX/reg.log" ;;
  *SteamSetup.exe) mkdir -p "$WINEPREFIX/drive_c/Program Files (x86)/Steam/steamapps"; : >"$WINEPREFIX/drive_c/Program Files (x86)/Steam/steam.exe" ;;
  *steam.exe)
    case "$*" in *steam://install/*)
      printf '"AppState"\n{\n\t"appid"\t\t"282440"\n\t"StateFlags"\t\t"1026"\n\t"BytesToDownload"\t\t"1000"\n\t"BytesDownloaded"\t\t"250"\n}\n' \
        >"$WINEPREFIX/drive_c/Program Files (x86)/Steam/steamapps/appmanifest_282440.acf" ;;
    esac ;;
esac
exit 0
WINE
printf '#!/bin/sh\nexit 0\n' >"$box/make/wine/bin/wineserver"
chmod +x "$box/make/wine/bin/wine" "$box/make/wine/bin/wineserver"
for f in winemac.so win32u.so opengl32.so ntdll.so; do print -r -- "stock $f" >"$box/make/wine/lib/wine/aarch64-unix/$f"; done
print -r -- "stock opengl32.dll" >"$box/make/wine/lib/wine/i386-windows/opengl32.dll"
tar -cJf "$box/engine.tar.xz" -C "$box/make" wine
print -r -- "not really Valve's" >"$box/SteamSetup.exe"

export QLOM_ROOT="$box/root" QLOM_TEST_ENGINE="$box/engine.tar.xz" QLOM_TEST_STEAM="$box/SteamSetup.exe"
export QLOM_DISPLAY="3840x2160 1920x1080"
q() { "$box/res/qlom.zsh" "$@" 2>&1; }
S="$QLOM_ROOT/support" U="$QLOM_ROOT/support/engine/lib/wine/aarch64-unix"
steam="$S/bottle/drive_c/Program Files (x86)/Steam"

pass=0 failed=0
ok() { # <what> <command...>
  local what=$1; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else failed=$((failed + 1)); print -r -- "FAIL: $what"; fi
}
has() { [[ "$1" == *"$2"* ]]; }
# what the detached "wine" leaves comes a moment after the command that started it has returned
seen() { local i; for i in {1..40}; do grep -q -- "$1" "$2" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
hasnt() { [[ "$1" != *"$2"* ]]; }

out=$(q status)
ok "status before anything: no engine" has "$out" "engine=none"
ok "status: defaults fps 250" has "$out" "fps=250"
ok "status: defaults retina on" has "$out" "retina=on"
ok "status: the display's two sizes" has "$out" "display_pixels=3840x2160"
ok "play before install is refused" has "$(q play || true)" "@error Install first."

out=$(q install)
ok "install: five steps announced" has "$out" "@step 5 5 Quake Live, in Steam"
ok "install: progress lines or none, then done" has "$out" "@done"
ok "install: engine unpacked and stamped" test -f "$S/engine/.ql-engine"
ok "install: my driver is in" grep -q "mine winemac.so" "$U/winemac.so"
ok "install: the engine's driver kept" grep -q "stock winemac.so" "$U/winemac.so.stock"
ok "install: glmt is in, with no .stock" test -f "$U/libglmt.dylib" -a ! -f "$U/libglmt.dylib.stock"
ok "install: the 32-bit opengl32 is mine" grep -q "mine opengl32.dll" "$S/engine/lib/wine/i386-windows/opengl32.dll"
ok "install: the engine's 32-bit opengl32 kept" grep -q "stock opengl32.dll" "$S/engine/lib/wine/i386-windows/opengl32.dll.stock"
ok "install: components stamp" grep -q "test-1" "$S/engine/.ql-components"
ok "install: bottle made" test -f "$S/bottle/system.reg"
ok "install: Retina mode y in the registry" grep -q "RetinaMode /d y" "$S/bottle/reg.log"
ok "install: Steam installed" test -f "$steam/steam.exe"
ok "install: Steam started on the game's install page" seen "steam://install/282440" "$S/calls.log"
seen StateFlags "$steam/steamapps/appmanifest_282440.acf"
ok "install: Steam starts without its GPU process" seen "steam.exe -cef-disable-gpu steam://install/282440" "$S/calls.log"
ok "install: Wine got the three defaults" grep -q "GLMT_PRESENT=async WINEMSYNC=1 WINE_GLMT_BATCH=1 WINE_GLMT_FULLSCREEN_SPACE=1" "$S/calls.log"
out=$(q status)
ok "status: the game downloads" has "$out" "game=downloading"
ok "status: bytes so far" has "$out" "game_bytes=250"
ok "status: bytes in all" has "$out" "game_total=1000"
ok "play while the game downloads is refused" has "$(q play || true)" "@error Quake Live is not installed yet."

# Steam finished the download
mkdir -p "$steam/steamapps/common/Quake Live"
: >"$steam/steamapps/common/Quake Live/quakelive_steam.exe"
sed -i.bak 's/"1026"/"4"/' "$steam/steamapps/appmanifest_282440.acf"
ok "status: the game is there" has "$(q status)" "game=ok"

: >"$S/calls.log"
out=$(q install)
ok "install again: nothing downloaded, done" has "$out" "@done"
ok "install again: Wine not started (everything was there)" test ! -s "$S/calls.log"

out=$(q play)
ok "play: started" has "$out" "@done started"
ok "play: 250 fps, vsync off, the display's pixels" seen "-applaunch 282440 +set com_maxfps 250 +set r_swapInterval 0 +set r_fullscreen 1 +set r_mode -1 +set r_customWidth 3840 +set r_customHeight 2160" "$S/calls.log"
ok "play: Steam starts without its GPU process" seen "steam.exe -cef-disable-gpu -applaunch" "$S/calls.log"
ok "status: Steam remembers no login yet" has "$(q status)" $'steambg=on\nsteam_login=no'
# Steam has a login it remembers
mkdir -p "$steam/config"
printf '"users"\n{\n\t"7656"\n\t{\n\t\t"AccountName"\t\t"someone"\n\t\t"RememberPassword"\t\t"1"\n\t}\n}\n' >"$steam/config/loginusers.vdf"
ok "status: Steam remembers a login" has "$(q status)" "steam_login=yes"
: >"$S/calls.log"; q play >/dev/null
ok "play: with a remembered login Steam starts without its window" seen "steam.exe -cef-disable-gpu -silent -applaunch 282440" "$S/calls.log"
q set steambg off >/dev/null; : >"$S/calls.log"; q play >/dev/null
ok "play: with Steam in the background off its window shows" seen "steam.exe -cef-disable-gpu -applaunch 282440" "$S/calls.log"
q set steambg on >/dev/null
ok "play: logs started afresh" test -f "$QLOM_ROOT/logs/wine.log"
# how far a start is: the note Play leaves, against what Steam and glmt write afterwards
stage() { q status | sed -n 's/^launch=//p'; }
logline() { print -r -- "[$1] $2"$'\r'; }
mkdir -p "$steam/logs"
ok "start: first Steam is coming up" test "$(stage)" = steam
ok "start: Steam is there and has not logged on" test "$(QLOM_TEST_RUNNING='session steam' stage)" = signin
logline "2001-01-01 00:00:00" "[Logged On, 4, 7] [U:1:1] an old session's line" >"$steam/logs/connection_log.txt"
ok "start: a log-on from before the start does not count" test "$(QLOM_TEST_RUNNING='session steam' stage)" = signin
logline "2099-01-01 00:00:00" "Downloading update (1,024 of 40,960 KB)..." >"$steam/logs/bootstrap_log.txt"
ok "start: Steam is updating itself" test "$(QLOM_TEST_RUNNING='session steam' stage)" = steamupdate
logline "2099-01-01 00:00:05" "Verifying installation..." >>"$steam/logs/bootstrap_log.txt"
ok "start: and is done with that" test "$(QLOM_TEST_RUNNING='session steam' stage)" = signin
logline "2099-01-01 00:00:10" "[Logged On, 4, 7] [U:1:1] RecvMsgClientLogOnResponse() : processing complete" >>"$steam/logs/connection_log.txt"
ok "start: Steam logged on, the game is being started" test "$(QLOM_TEST_RUNNING='session steam' stage)" = game
logline "2099-01-01 00:00:11" "AppID 282440 state changed : Update Required,Update Queued,Update Running," >"$steam/logs/content_log.txt"
ok "start: Steam updates the game first" test "$(QLOM_TEST_RUNNING='session steam' stage)" = update
logline "2099-01-01 00:00:40" "AppID 282440 state changed : Fully Installed,App Running," >>"$steam/logs/content_log.txt"
ok "start: the update is through" test "$(QLOM_TEST_RUNNING='session steam' stage)" = game
ok "start: the game's process is there, its picture not yet" test "$(QLOM_TEST_RUNNING='session steam game' stage)" = game
print -r -- "glmt: Metal device" >"$QLOM_ROOT/logs/glmt.log"
ok "start: glmt has written, the start is over" test -z "$(QLOM_TEST_RUNNING='session steam game' stage)"
ok "start: the note is gone with it" test ! -e "$S/.launch"
rm -f "$steam/logs/"*.txt
print -r -- "1 warm 2001-01-01 00:00:00" >"$S/.launch"
ok "start: three minutes and no game is said" test "$(QLOM_TEST_RUNNING='session steam' stage)" = stalled
ok "start: and only once" test -z "$(QLOM_TEST_RUNNING='session steam' stage)"
print -r -- "$(( $(date +%s) - 300 )) cold 2001-01-01 00:00:00" >"$S/.launch"
mv "$steam/config/loginusers.vdf" "$steam/config/loginusers.vdf.away"
ok "start: a sign-in by hand gets longer than three minutes" test "$(QLOM_TEST_RUNNING='session steam' stage)" = signin
mv "$steam/config/loginusers.vdf.away" "$steam/config/loginusers.vdf"
print -r -- "1 cold 2001-01-01 00:00:00" >"$S/.launch"
ok "start: a session that ended without the game is said to have failed" test "$(stage)" = failed
ok "start: and only once" test -z "$(stage)"
q play >/dev/null
ok "play: a Steam that already runs is not waited for" test "$(QLOM_TEST_RUNNING='session steam' q play >/dev/null; QLOM_TEST_RUNNING='session steam' stage)" = game
ok "play: a session without Steam still has its sign-in ahead" test "$(QLOM_TEST_RUNNING='session' q play >/dev/null; QLOM_TEST_RUNNING='session steam' stage)" = signin
logline "2099-01-01 00:00:10" "[Logged On, 4, 7] [U:1:1] RecvMsgClientLogOnResponse() : processing complete" >"$steam/logs/connection_log.txt"
logline "2099-01-01 00:05:00" "Downloading update (1,024 of 40,960 KB)..." >"$steam/logs/bootstrap_log.txt"
ok "start: Steam's background update after its log-on is not this start's" test "$(QLOM_TEST_RUNNING='session steam' stage)" = game
rm -f "$steam/logs/"*.txt
q stop >/dev/null
ok "stop: ends a start that was under way" test ! -e "$S/.launch"
sed -i.bak 's/"StateFlags"\([^"]*\)"4"/"StateFlags"\1"1092"/' "$steam/steamapps/appmanifest_282440.acf"
ok "status: the game counts as installed while it runs with an update waiting" has "$(q status)" "game=ok"
sed -i.bak 's/"StateFlags"\([^"]*\)"1092"/"StateFlags"\1"4"/' "$steam/steamapps/appmanifest_282440.acf"

ok "set fps 125" has "$(q set fps 125)" "@done"
ok "set retina off" has "$(q set retina off)" "@done"
ok "status: Steam quits with the game by default" has "$(q status)" "quitsteam=on"
ok "set quitsteam off" has "$(q set quitsteam off)" "@done"
ok "status: quitsteam off" has "$(q status)" "quitsteam=off"
ok "stop: done (no session runs here, so nothing is asked of Steam)" has "$(q stop)" "@done"
ok "set: a value that is not offered is refused" has "$(q set fps 144 || true)" "@error"
ok "set: a key that is not offered is refused" has "$(q set hud on || true)" "@error"
out=$(q status)
ok "status: fps 125" has "$out" "fps=125"
ok "status: retina off wanted, on applied" has "$out" $'retina=off\nretina_applied=on'
: >"$S/calls.log"
q play >/dev/null
ok "play after the change: Retina mode n written first" grep -q "RetinaMode /d n" "$S/bottle/reg.log"
ok "play after the change: 125 fps at the display's points" seen "+set com_maxfps 125 +set r_swapInterval 0 +set r_fullscreen 1 +set r_mode -1 +set r_customWidth 1920 +set r_customHeight 1080" "$S/calls.log"
ok "status: retina off applied" has "$(q status)" "retina_applied=off"

out=$(q env)
ok "env: the bottle" has "$out" "WINEPREFIX=$S/bottle"
ok "env: the arguments" has "$out" "args: -applaunch 282440 +set com_maxfps 125"

# a new version of the app brings new components
print -r -- "test-2" >"$box/res/components/STAMP"
print -r -- "mine2 winemac.so libglmt.dylib" >"$box/res/components/winemac.so"
ok "status: the engine's pieces are old" has "$(q status)" "components=old"
q play >/dev/null
ok "play: the new pieces went in first" grep -q "mine2 winemac.so" "$U/winemac.so"
ok "play: the engine's own driver is still the kept one" grep -q "stock winemac.so" "$U/winemac.so.stock"
ok "status: the pieces are current" has "$(q status)" "components=ok"

rm -f "$U/libglmt.dylib"
ok "status: an engine that lost glmt counts as old" has "$(q status)" "components=old"
q play >/dev/null
ok "play: glmt is put back before the game starts" test -f "$U/libglmt.dylib"
rm -f "$U/libglmt.dylib"
out=$(q repair)
ok "repair: three steps, done" has "$out" "@step 3 3"
ok "repair: glmt is back" test -f "$U/libglmt.dylib"
ok "repair: the game is kept" test -f "$steam/steamapps/common/Quake Live/quakelive_steam.exe"

# two at once
mkdir -p "$S/.lock"; print -r -- $$ >"$S/.lock/pid"
ok "a second run while one works is refused" has "$(q repair || true)" "already at work"
rm -rf "$S/.lock"
mkdir -p "$S/.lock"; print -r -- 999999 >"$S/.lock/pid"
ok "a lock whose process is gone is taken over" has "$(q repair)" "@done"

out=$(q uninstall)
ok "uninstall: done" has "$out" "@done"
ok "uninstall: engine gone" test ! -e "$S/engine"
ok "uninstall: bottle and the game gone" test ! -e "$S/bottle"
ok "uninstall: downloads gone" test ! -e "$QLOM_ROOT/downloads"
ok "uninstall: the logs stay" test -f "$QLOM_ROOT/logs/install.log"
ok "status after uninstall: nothing" has "$(q status)" $'engine=none\ncomponents=none\nbottle=none\nsteam=none\ngame=none'

print -r -- "$pass passed, $failed failed"
(( failed == 0 ))
