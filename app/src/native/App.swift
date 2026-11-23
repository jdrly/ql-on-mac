// QL on Mac: the app's state and its one window's wiring. Everything it does goes through the
// backend in the bundle (Resources/qlom.zsh); this file starts it, reads its "@" lines and keeps
// what the window shows. The structure follows GW2 on Mac's app, cut down to one window.

import AppKit
import SwiftUI

let appName = "QL on Mac"

struct Step: Identifiable, Equatable {
  let id: Int
  let title: String
  let detail: String
}

enum Operation: String {
  case install, repair, uninstall
}

// What the window is showing
enum Phase: Equatable {
  case loading          // the first status has not come back yet
  case setup            // nothing, or not everything, is installed
  case working          // install or repair runs, or has just failed
  case waitingForGame   // Steam is in; Quake Live is not downloaded yet
  case ready
}

// A start of the game that did not get there
enum LaunchProblem: Equatable {
  case failed    // the session ended before the game came
  case stalled   // Steam runs, and after minutes there is still no game
}

@MainActor
final class Model: ObservableObject {
  struct Progress: Equatable {
    let done: Int64
    let total: Int64
  }

  @Published var status: [String: String] = [:]
  @Published var loaded = false
  @Published var operation: Operation?
  @Published var stepIndex = 0            // the step the backend is at, from 1; 0 before the first
  @Published var progress: Progress?
  @Published var failure: String?         // why the last install or repair ended, shown at its step
  @Published var playError: String?
  @Published var launching = false
  @Published var settingBusy = false
  @Published var stopping = false         // Steam is being quit (by More, by the game's end or by the app's)
  @Published var launchProblem: LaunchProblem?

  static let shared = Model()

  static let installSteps = [
    Step(id: 1, title: "Wine, to run Windows programs", detail: "126 MB download"),
    Step(id: 2, title: "Graphics for Quake Live on Metal", detail: ""),
    Step(id: 3, title: "A Windows environment for the game", detail: ""),
    Step(id: 4, title: "Steam, from Valve", detail: ""),
    Step(id: 5, title: "Quake Live, in Steam", detail: "You sign in and install it there"),
  ]

  let script: URL
  private let preview: Bool
  private var process: Process?
  private var lastError: String?          // the running operation's last "@error" line
  private var timer: Timer?
  private var refreshing = false
  private var ticks = 0
  private var startAsked: Date?           // Play was just answered; the next status may predate it

  init(resources: URL = Bundle.main.resourceURL ?? URL(fileURLWithPath: "/")) {
    script = resources.appendingPathComponent("qlom.zsh")
    preview = false
  }

  // A fixed state for the headless render (Render.swift): no backend, no timer
  init(previewStatus: [String: String], operation: Operation? = nil, stepIndex: Int = 0,
       progress: Progress? = nil, failure: String? = nil, playError: String? = nil,
       launchProblem: LaunchProblem? = nil) {
    script = URL(fileURLWithPath: "/dev/null")
    preview = true
    status = previewStatus
    loaded = true
    self.operation = operation
    self.stepIndex = stepIndex
    self.progress = progress
    self.failure = failure
    self.playError = playError
    self.launchProblem = launchProblem
  }

  // MARK: What the window asks

  var phase: Phase {
    if operation == .install || operation == .repair || failure != nil { return .working }
    if !loaded { return .loading }
    let base = status["engine"] == "ok" && status["bottle"] == "ok" && status["steam"] == "ok"
    // a start that is under way stays on Play's screen, also while Steam updates the game first
    if base && (status["game"] == "ok" || starting) { return .ready }
    if base { return .waitingForGame }
    return .setup
  }

  var steps: [Step] {
    operation == .repair ? Array(Model.installSteps.prefix(3)) : Model.installSteps
  }

  var sessionRunning: Bool { status["session"] == "running" }
  var gameRunning: Bool { status["game_running"] == "yes" }
  // How far a start of the game is, by the backend: steam, steamupdate, signin, update, game.
  // Empty when none is under way.
  var launchStage: String {
    let stage = status["launch"] ?? ""
    return stage == "failed" || stage == "stalled" ? "" : stage
  }
  var starting: Bool { !launchStage.isEmpty }
  var fps: Int { Int(status["fps"] ?? "") ?? 250 }
  var retina: Bool { status["retina"] != "off" }
  var quitSteamWithGame: Bool { status["quitsteam"] != "off" }
  var steamInBackground: Bool { status["steambg"] != "off" }
  // Steam has a login it uses by itself: only then can it start without its window
  var steamSignedIn: Bool { status["steam_login"] == "yes" }
  var isPreview: Bool { preview }
  // the display is one macOS scales: without that, Retina mode changes nothing
  var displayScaled: Bool {
    guard let pixels = status["display_pixels"], let points = status["display_points"], !pixels.isEmpty else { return true }
    return pixels != points
  }
  // the size the game starts at with the setting as it is
  var resolution: String {
    let value = (retina ? status["display_pixels"] : status["display_points"]) ?? ""
    return value.replacingOccurrences(of: "x", with: " × ")
  }
  // the Retina setting differs from what the running session started with
  var retinaWaits: Bool {
    guard sessionRunning, let applied = status["retina_applied"], !applied.isEmpty else { return false }
    return applied != (retina ? "on" : "off")
  }
  var gameDownload: Progress? {
    guard let done = Int64(status["game_bytes"] ?? ""), let total = Int64(status["game_total"] ?? ""), total > 0 else { return nil }
    return Progress(done: min(done, total), total: total)
  }
  var logsFolder: URL {
    URL(fileURLWithPath: status["logs"] ?? (NSHomeDirectory() + "/Library/Logs/" + appName))
  }

  // MARK: Status

  func start() {
    guard !preview else { return }
    refresh()
    // Every two seconds; every second while the game is being started, so that its stages show;
    // every ten while the game draws: a status is a handful of short processes, and a program
    // that wakes up on a timer beside the game is what cost it frames before.
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.ticks += 1
        let every = self.starting || self.launching ? 1 : self.gameRunning ? 10 : 2
        if self.ticks % every == 0 { self.refresh() }
      }
    }
  }

  func refresh() {
    guard !preview, !refreshing else { return }
    refreshing = true
    let script = script
    let environment = Model.environment()
    Task {
      let output = await Model.capture(script: script, arguments: ["status"], environment: environment)
      var values: [String: String] = [:]
      for line in output.split(separator: "\n") {
        guard let eq = line.firstIndex(of: "=") else { continue }
        values[String(line[line.startIndex..<eq])] = String(line[line.index(after: eq)...])
      }
      refreshing = false
      if !values.isEmpty {
        // a status that was on its way while Play ran does not know of the start yet
        if (values["launch"] ?? "").isEmpty, values["game_running"] != "yes", let asked = startAsked,
           Date().timeIntervalSince(asked) < 3 {
          values["launch"] = "steam"
        }
        let gameWasRunning = gameRunning
        status = values
        loaded = true
        // the backend says once that a start did not get to the game
        switch values["launch"] {
        case "failed": launchProblem = .failed
        case "stalled": launchProblem = .stalled
        default: if gameRunning { launchProblem = nil }
        }
        // the game has quit while the app watched: Steam goes too, if that is wanted
        if gameWasRunning && !gameRunning && sessionRunning && quitSteamWithGame { quitSteam() }
      }
    }
  }

  // The display Wine calls the main one, in pixels and in points, for the backend
  static func environment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    if let screen = NSScreen.screens.first {
      let points = screen.frame.size
      let scale = screen.backingScaleFactor
      env["QLOM_DISPLAY"] = "\(Int(points.width * scale))x\(Int(points.height * scale)) \(Int(points.width))x\(Int(points.height))"
    }
    return env
  }

  nonisolated static func capture(script: URL, arguments: [String], environment: [String: String]) async -> String {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path] + arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
          try process.run()
          let data = pipe.fileHandleForReading.readDataToEndOfFile()
          process.waitUntilExit()
          continuation.resume(returning: String(decoding: data, as: UTF8.self))
        } catch {
          continuation.resume(returning: "@error \(error.localizedDescription)")
        }
      }
    }
  }

  // MARK: Install, repair, uninstall (long: the window follows their lines)

  func run(_ operation: Operation) {
    guard self.operation == nil, !preview else { return }
    self.operation = operation
    stepIndex = 0
    progress = nil
    failure = nil
    playError = nil
    lastError = nil

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [script.path, operation.rawValue]
    process.environment = Model.environment()
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let reader = LineReader { [weak self] line in
      Task { @MainActor in
        guard let self else { return }
        if line.hasPrefix("@step ") {
          let parts = line.split(separator: " ")
          if parts.count >= 2, let n = Int(parts[1]) { self.stepIndex = n; self.progress = nil }
        } else if line.hasPrefix("@progress ") {
          let parts = line.split(separator: " ")
          if parts.count == 3, let done = Int64(parts[1]), let total = Int64(parts[2]), total > 0 {
            self.progress = Progress(done: min(done, total), total: total)
          }
        } else if line.hasPrefix("@error ") {
          self.lastError = String(line.dropFirst(7))
        }
      }
    }
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        reader.finish()
      } else {
        reader.feed(data)
      }
    }
    process.terminationHandler = { [weak self] finished in
      let code = finished.terminationStatus
      // a moment for the last lines to arrive from the pipe
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        MainActor.assumeIsolated {
          guard let self else { return }
          let lastError = self.lastError
          self.process = nil
          self.operation = nil
          self.progress = nil
          if code != 0 && operation != .uninstall && lastError != "Cancelled" {
            self.failure = lastError ?? "It stopped without saying why. Details are in \(self.logsFolder.path)/install.log."
          } else if code != 0 && operation == .uninstall {
            self.playError = lastError
          }
          if lastError == "Cancelled" { self.stepIndex = 0 }
          self.refresh()
        }
      }
    }
    do {
      try process.run()
      self.process = process
    } catch {
      self.operation = nil
      failure = "The installer could not be started: \(error.localizedDescription)"
    }
  }

  // Cancel: the script gets SIGTERM, ends what it started and keeps the steps that were done
  func cancel() { process?.terminate() }

  func dismissFailure() {
    failure = nil
    stepIndex = 0
  }

  // MARK: Short commands

  private func command(_ arguments: [String], then: @escaping (_ error: String?) -> Void = { _ in }) {
    guard !preview else { return }
    let script = script
    let environment = Model.environment()
    Task {
      let output = await Model.capture(script: script, arguments: arguments, environment: environment)
      let error = output.split(separator: "\n").first { $0.hasPrefix("@error ") }.map { String($0.dropFirst(7)) }
      refresh()
      then(output.contains("@done") ? nil : (error ?? "That did not work. Details are in \(logsFolder.path)."))
    }
  }

  func play() {
    guard !launching else { return }
    launching = true
    playError = nil
    launchProblem = nil
    command(["play"]) { [weak self] error in
      guard let self else { return }
      self.launching = false
      self.playError = error
      // until the next status says where the start is, so that the button does not flash "Play"
      if error == nil && !self.gameRunning && self.status["launch", default: ""].isEmpty {
        self.startAsked = Date()
        self.status["launch"] = "steam"
      }
    }
  }

  func showSteam() {
    guard !launching else { return }
    launching = true
    playError = nil
    launchProblem = nil
    command(["steam"]) { [weak self] error in
      self?.launching = false
      self?.playError = error
    }
  }

  func quitSteam(then: @escaping () -> Void = {}) {
    guard !stopping else { then(); return }
    stopping = true
    launchProblem = nil
    command(["stop"]) { [weak self] _ in
      self?.stopping = false
      then()
    }
  }

  func set(_ key: String, _ value: String) {
    guard !settingBusy else { return }
    settingBusy = true
    status[key] = value   // the control answers at once; the next status confirms it
    command(["set", key, value]) { [weak self] _ in self?.settingBusy = false }
  }

  func showLogs() {
    try? FileManager.default.createDirectory(at: logsFolder, withIntermediateDirectories: true)
    NSWorkspace.shared.open(logsFolder)
  }

  func confirmUninstall() {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Uninstall Quake Live and Steam?"
    alert.informativeText = "Steam and Quake Live's files in \(appName)'s folder are removed, with the Wine engine. Settings Steam Cloud holds stay there. The logs stay on this Mac."
    alert.addButton(withTitle: "Uninstall")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    if alert.runModal() == .alertFirstButtonReturn { run(.uninstall) }
  }
}

// Splits a byte stream into lines (the pipe hands over arbitrary chunks). From GW2 on Mac's app.
final class LineReader: @unchecked Sendable {
  private var buffer = Data()
  private let lock = NSLock()
  private let emit: (String) -> Void

  init(emit: @escaping (String) -> Void) { self.emit = emit }

  func feed(_ data: Data) {
    lock.lock()
    buffer.append(data)
    var lines: [String] = []
    while let nl = buffer.firstIndex(of: 0x0A) {
      lines.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
      buffer.removeSubrange(buffer.startIndex...nl)
    }
    lock.unlock()
    lines.forEach(emit)
  }

  func finish() {
    lock.lock()
    let rest = buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
    buffer.removeAll()
    lock.unlock()
    if let rest { emit(rest) }
  }
}

// MARK: - The app

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  // Quitting the app quits Steam, and the game with it. It asks first when that would end a game
  // or stop Steam's download of it; an idle Steam just goes.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let model = Model.shared
    // a start that was just asked for counts as a session: the status may not show it yet
    guard !model.isPreview, model.sessionRunning || model.operation != nil || model.launching || model.starting else { return .terminateNow }
    let downloading = model.phase == .waitingForGame && model.gameDownload != nil
    if model.gameRunning || downloading {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = model.gameRunning ? "Quit Quake Live and Steam?" : "Quit Steam?"
      alert.informativeText = model.gameRunning
        ? "Quake Live is running. Quitting \(appName) ends the game and Steam."
        : "Steam is downloading Quake Live. It picks the download up again the next time it starts."
      alert.addButton(withTitle: model.gameRunning ? "Quit Both" : "Quit Steam")
      alert.addButton(withTitle: "Cancel")
      if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
    }
    model.cancel()
    model.quitSteam { NSApp.reply(toApplicationShouldTerminate: true) }
    return .terminateLater
  }
}

struct QLonMacApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @ObservedObject private var model = Model.shared
  @StateObject private var updates = Updates()

  var body: some Scene {
    Window(appName, id: "main") {
      MainView(model: model, updates: updates)
        .onAppear { model.start() }
    }
    .windowResizability(.contentSize)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") { updates.check() }
          .disabled(!updates.available)
      }
    }
  }
}

@main
enum Main {
  @MainActor static func main() {
    let arguments = CommandLine.arguments
    if let i = arguments.firstIndex(of: "--render"), i + 1 < arguments.count {
      Render.run(into: URL(fileURLWithPath: arguments[i + 1]))
    } else {
      QLonMacApp.main()
    }
  }
}
