# QL on Mac (the app)

One window that sets Quake Live up on this Mac and starts it: its own Wine engine with glmt,
its own bottle, Steam from Valve, the game through Steam. It follows GW2 on Mac's app
(`jdrly/gw2-on-mac`: a SwiftUI window over a shell backend in the bundle, Sparkle for updates)
and is cut down to what fits on one screen.

Status (2026-11-23): written. The backend is tested in a sandbox on Linux (57 checks, a
Wine that only pretends). **The Swift has not been compiled**, nothing of the window has been
seen, and no real install has run. It never touches a development checkout's `work/`.

## The window

Three things can be on it:

- **Install**: five steps with a progress bar where one can be measured, Cancel, and after a
  failure the reason at the step that failed with Try Again.
  1. Wine, to run Windows programs (athei's Mach9, 126 MB, the pin in `scripts/common.zsh`)
  2. Graphics for Quake Live on Metal (my five files into the engine, below)
  3. A Windows environment for the game (the bottle)
  4. Steam, from Valve (`SteamSetup.exe` from Valve's CDN, silently)
  5. Quake Live, in Steam (Steam opens on the game's install page; you sign in there)
- **Waiting for Steam's download**, read from Steam's own `appmanifest_282440.acf`; it turns
  into Ready by itself.
- **Ready**: Play, and three settings.

| Setting | What it does |
|---|---|
| Frame cap, 125 or 250 | `+set com_maxfps`. The game saves it in its config, and Steam Cloud carries that to the player's other computers; the window says so. |
| Retina | Wine's `RetinaMode` in the bottle, and the size the game starts at: the display's pixels (on) or its points (off). It applies when a new Wine session starts, so with Steam running the window offers Quit Steam. Disabled on a display macOS does not scale. **Off has never run through glmt.** |
| Automatic updates | Sparkle's automatic checks, with Check Now. Disabled, with the reason, in a build without a feed. |

"More" has Open Steam, Quit Steam, Show Logs, Repair and Uninstall…

Everything else is fixed to what was measured in play: `GLMT_PRESENT=async`,
the game's window in a Space of its own, OpenGL calls in batches, vsync off, fullscreen at the
display's own size.

## What it changes on disk

| Path | What | Uninstall |
|---|---|---|
| `~/Library/Application Support/QL on Mac/engine/` | the Wine engine with my five files | removed |
| `…/QL on Mac/bottle/` | the Wine prefix: Steam and the game | removed |
| `…/QL on Mac/settings.conf` | the two settings | removed |
| `~/Library/Caches/QL on Mac/downloads/` | the engine's archive, `SteamSetup.exe` | removed |
| `~/Library/Logs/QL on Mac/` | `install.log`, `wine.log`, `glmt.log` | kept |

## The backend

`Resources/qlom.zsh` (`src/qlom.zsh`), with `scripts/common.zsh` beside it: the repository's own
scripts pointed at the folders above. `status`, `install`, `play`, `steam`, `stop`,
`set fps 125|250`, `set retina on|off`, `repair`, `uninstall`, `env`. Lines for the window start
with `@` (`@step`, `@progress`, `@error`, `@done`).

- Every install step is skipped when it is done, so Install after a failure or a cancel continues.
- **A new version's files reach the engine.** `components/STAMP` (the commit and each file's
  sha256) is copied into the engine with the files; when the bundle's differs, Play puts the new
  ones in first, with no session running (with one, it asks to quit Steam).
- Play starts Steam detached, so the game outlives the app.
- `QLOM_ROOT=/abs/dir` puts every path under that folder.

## Building (on the Mac; not while the game runs)

```sh
app/scripts/stage-components.zsh    # compiles glmt, the Mac driver, win32u and the opengl32 pair
                                    # from this checkout into app/prebuilt/ (minutes)
app/build.zsh                       # app/dist/QL on Mac.app, ad hoc signed
app/build.zsh --render              # also every state of the window as PNGs in work/app-renders
```

`QL_ON_MAC_NO_COMPONENTS=1 app/build.zsh --render` builds without `app/prebuilt/`, for the
pictures only. Needs Xcode 27; Sparkle 2.10.0 is downloaded at a pinned sha256.

The components are always built from the checkout, never copied out of an engine: on
2026-11-23 the development engine's driver still carried a patch that had been taken out.

## Testing

`app/scripts/test-backend.zsh` runs the backend from a first install to an uninstall in
`work/app-sandbox/test`, on any machine: a stand-in engine whose `wine` writes down what it was
asked, stand-in components, a stand-in `SteamSetup.exe`. Not covered: what needs a running Wine
session to be seen, `codesign`, the display's size, and the window.

## Before anyone else gets it

Three things are open; none blocks building it or using it on the Mac it was built on:

- **An update feed.** Sparkle needs a public address for `appcast.xml` and the DMG: a GitHub
  release, once there is one.
- **Signing.** A Developer ID signature and notarization (GW2 on Mac's `release.sh` does both).
  The engine's files are re-signed ad hoc when they go in, as the scripts do.
- **The batching DLL.** `opengl32.dll` is new 32-bit code in the game's process. I don't know
  what anti-cheat the game runs (its Steam page doesn't list VAC). I took that risk for my own
  account, and a player who installs the app takes it for theirs: the app has to say so before
  it installs the pair.

Also open: an icon (the bundle has none), a first real install, and Retina off.
