# QL on Mac (the app)

One window that sets Quake Live up on this Mac and starts it: its own Wine engine with glmt,
its own bottle, Steam from Valve, the game through Steam. It follows
[GW2 on Mac](https://github.com/jdrly/gw2-on-mac)'s app (a SwiftUI window over a shell backend in
the bundle, [Sparkle](https://github.com/sparkle-project/Sparkle) for updates)
and is cut down to what fits on one screen.

Status (2026-11-23): 0.1.0 is out as a signed and notarized DMG, with its update feed. Every
state of the window has been rendered to pictures and looked at. The backend passes its sandbox
test (88 checks, a Wine that only pretends). A first real install ran on 2026-11-23, with one
hang of Steam's web helper on the way (below), and I play from the app since. Not tried yet:
Retina off.
It never touches a development checkout's `work/`.

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
| Steam in the background | On by default. Play starts Steam without its window (`-silent`). The row shows, and the setting counts, only once Steam remembers a login: before that its window has to show so that you can sign in. A Steam that already runs keeps the window it has. |
| Quit Steam with the game | On by default. When the game has quit while the app is open, the app quits Steam too. |
| Automatic updates | Sparkle's automatic checks, with Check Now. Disabled, with the reason, in a build without a feed. |

Quitting the app quits Steam, and with it the game. It asks first if the game runs or Steam is
still downloading it. Steam is always asked to quit by itself first (`steam.exe -shutdown`), so
that it finishes syncing the game's config to Steam Cloud; after twenty seconds the Wine session
ends whatever is left. Steam starts with `-cef-disable-gpu`, see below.

**Play says how far the start is.** With Steam in the background nothing shows for the half
minute Steam takes to come up and sign in, so the Play button carries the stage: Starting Steam,
Steam Is Updating Itself, Signing In to Steam (or Waiting for Your Steam Sign-In, with Steam's
window open), Steam Is Updating Quake Live with the download's progress, Starting Quake Live.
It becomes Quake Live Is Running once the game draws. If Steam's session ends before the game
came, the window says so and offers the logs; after three minutes without the game it says that
and offers Steam's window.

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
`set fps 125|250`, `set retina on|off`, `set quitsteam on|off`, `set steambg on|off`, `repair`,
`uninstall`, `env`. Lines for the window start
with `@` (`@step`, `@progress`, `@error`, `@done`).

- Every install step is skipped when it is done, so Install after a failure or a cancel continues.
- **A new version's files reach the engine.** `components/STAMP` (the commit and each file's
  sha256) is copied into the engine with the files; when the bundle's differs, Play puts the new
  ones in first, with no session running (with one, it asks to quit Steam).
- Play starts Steam detached from the backend's own process. The app ends the session when it
  quits.
- **Where a start is, `launch=` in `status`.** Play leaves a note with the time, and `status`
  compares it with what has been written since: Steam's `logs/bootstrap_log.txt` (its own
  update), `logs/connection_log.txt` (`[Logged On`), `logs/content_log.txt` (the game's update),
  the game's process, and `glmt.log` (the game draws). The stages are `steam`, `steamupdate`,
  `signin`, `update`, `game`; `failed` and `stalled` are said once. The window asks every second
  while a start is under way, every two otherwise.
- **Steam starts with `-cef-disable-gpu`.** On this engine's `ntdll.so` Steam's web helper can
  deadlock at its start: Chrome's sampler suspends a thread inside `dlopen` while the in-process
  GPU thread loads a library with Wine's memory lock held
  ([jdrly/gw2-on-mac#304](https://github.com/jdrly/gw2-on-mac/issues/304) has the stacks). It
  happened at the app's first real install. Without the GPU thread the two don't meet, and Steam
  draws its own window in software. The fix proper is in my Wine fork's `ntdll.so`, which this
  project does not ship yet.
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

## The icon

`src/AppIcon.icon` is an Icon Composer document: two SVG layers and `icon.json` with the
background and each layer's glass settings. `build.zsh` compiles it with `actool` into
`Assets.car`, which macOS 26 and later draws as a Liquid Glass icon, and an `AppIcon.icns` as
the fallback. `scripts/icon-preview.zsh` renders it with Icon Composer's own `ictool` in the six
appearances and at the small sizes.

The mark is my own drawing, a ring and a blade that make a Q, in red and white on near black.
It is not id Software's Quake emblem and must not turn into a copy of it.

## Testing

`app/scripts/test-backend.zsh` runs the backend from a first install to an uninstall in
`work/app-sandbox/test`, on any machine: a stand-in engine whose `wine` writes down what it was
asked, stand-in components, a stand-in `SteamSetup.exe`. The stages of a start are checked
against log lines the test writes. Not covered: what needs a running Wine
session to be seen, `codesign`, the display's size, and the window.

## Releasing

```sh
QL_ON_MAC_FEED_URL=https://github.com/jdrly/ql-on-mac/releases/latest/download/appcast.xml \
QL_ON_MAC_ED_PUBLIC_KEY=yfxY4ORQfPcQWUMIenGgR0JIBYcL3+Osi3BP4KmPAH8= app/build.zsh
NOTARY_PROFILE=<profile> QL_ON_MAC_PUBLISH=1 app/scripts/release.zsh --draft
```

`scripts/release.zsh` follows GW2 on Mac's. It signs the app with my Developer ID under the
hardened runtime, packs `QL-on-Mac-<version>.dmg`, has Apple notarize it and staples the ticket.
Then it builds `appcast.xml` with Sparkle's `generate_appcast`, checks the feed's signature
against the key in the app, and creates a draft GitHub release on the commit the app was built
from. Publishing the draft makes the update live, because every install reads
`releases/latest/download/appcast.xml`. The script's header has the dry runs.

The release notes are `release-notes/<version>.md`. They go into the feed and the GitHub release.

The four Mach-O files in `Resources/components` get my signature in a release, as notarization
wants. The backend signs each ad hoc again when it copies it into the engine, as the scripts do.

Open: Retina off has not been played.
