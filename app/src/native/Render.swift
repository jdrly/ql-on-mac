// QLonMac --render <folder>: every state of the window as a PNG, light and dark, without showing
// anything. The view sits in a window that is never put on screen and is drawn at 2x; the app
// never activates. The way GW2 on Mac's ui-render does it. No backend runs: the states are fixed.

import AppKit
import SwiftUI

@MainActor
enum Render {
  static func run(into folder: URL) {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let display = ["display_pixels": "3840x2160", "display_points": "1920x1080"]
    let installed = display.merging(["engine": "ok", "components": "ok", "bottle": "ok", "steam": "ok"]) { $1 }
    let ready = installed.merging(["game": "ok", "fps": "250", "retina": "on", "retina_applied": "on", "session": "none", "game_running": "no", "steam_login": "yes"]) { $1 }
    let noFeed = Updates(previewVersion: "0.1.0", available: false, automatic: false)
    let withFeed = Updates(previewVersion: "0.1.0", available: true, automatic: true)

    let states: [(String, Model, Updates)] = [
      ("1-setup", Model(previewStatus: display.merging(["engine": "none"]) { $1 }), noFeed),
      ("2-installing", Model(previewStatus: display, operation: .install, stepIndex: 1,
                              progress: Model.Progress(done: 61 << 20, total: 126 << 20)), noFeed),
      ("3-install-failed", Model(previewStatus: display, stepIndex: 4,
                                  failure: "Steam's installer could not be downloaded from Valve."), noFeed),
      ("4-waiting", Model(previewStatus: installed.merging(["game": "downloading", "game_bytes": "412000000", "game_total": "1130000000", "session": "running"]) { $1 }), noFeed),
      ("5-ready", Model(previewStatus: ready), withFeed),
      ("6-ready-no-feed-no-login", Model(previewStatus: ready.merging(["fps": "125", "steam_login": "no"]) { $1 }), noFeed),
      ("7-ready-running-retina-waits", Model(previewStatus: ready.merging(["retina": "off", "session": "running", "game_running": "yes"]) { $1 }), withFeed),
      ("8-ready-display-not-scaled", Model(previewStatus: ready.merging(["display_points": "3840x2160"]) { $1 }), withFeed),
      ("10-starting-signing-in", Model(previewStatus: ready.merging(["session": "running", "launch": "signin"]) { $1 }), withFeed),
      ("11-starting-sign-in-by-hand", Model(previewStatus: ready.merging(["session": "running", "launch": "signin", "steam_login": "no"]) { $1 }), withFeed),
      ("12-starting-game-update", Model(previewStatus: ready.merging(["session": "running", "launch": "update", "game": "downloading", "game_bytes": "31000000", "game_total": "118000000"]) { $1 }), withFeed),
      ("13-starting-game", Model(previewStatus: ready.merging(["session": "running", "launch": "game", "game_running": "yes"]) { $1 }), withFeed),
      ("14-start-stalled", Model(previewStatus: ready.merging(["session": "running"]) { $1 }, launchProblem: .stalled), withFeed),
      ("15-start-failed", Model(previewStatus: ready, launchProblem: .failed), withFeed),
      ("9-ready-play-error", Model(previewStatus: ready, playError: "Quit Steam first: this version's files go into the engine before the game starts."), withFeed),
    ]
    for (name, model, updates) in states {
      for dark in [false, true] {
        let file = folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
        write(MainView(model: model, updates: updates), dark: dark, to: file)
      }
    }
    print("rendered \(states.count * 2) pictures into \(folder.path)")
  }

  private static func write<V: View>(_ view: V, dark: Bool, to file: URL) {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let host = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
    let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 460, height: 400), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.backgroundColor = .windowBackgroundColor
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    window.setContentSize(size)
    host.frame = CGRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    // a turn of the run loop, so that controls backed by AppKit views have drawn themselves
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))

    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = size
    appearance?.performAsCurrentDrawingAppearance {
      if let context = NSGraphicsContext(bitmapImageRep: rep) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.windowBackgroundColor.setFill()
        CGRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()
      }
      host.cacheDisplay(in: host.bounds, to: rep)
    }
    try? rep.representation(using: .png, properties: [:])?.write(to: file)
    window.close()
  }
}
