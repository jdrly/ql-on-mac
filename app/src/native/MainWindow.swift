// QL on Mac's one window. Three things can be on it: the install's steps, the wait for Steam's
// download of the game, and Play with the three settings. The rare actions are in "More".

import AppKit
import SwiftUI

enum Brand {
  // The action colour: on what can be clicked only, solid on the one main action.
  // White text on it has a contrast of 5.2 to 1.
  static let action = Color(red: 0.784, green: 0.216, blue: 0.106)
  static let width: CGFloat = 460
  static let pad: CGFloat = 28
}

struct PrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity, minHeight: 44)
      .background(RoundedRectangle(cornerRadius: 10).fill(enabled ? Brand.action : Color.secondary.opacity(0.45)))
      .opacity(configuration.isPressed ? 0.8 : 1)
      .contentShape(RoundedRectangle(cornerRadius: 10))
  }
}

struct MainView: View {
  @ObservedObject var model: Model
  @ObservedObject var updates: Updates

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text(appName)
        .font(.system(size: 22, weight: .semibold))
      switch model.phase {
      case .loading:
        Color.clear.frame(height: 220)
      case .setup, .working:
        InstallView(model: model)
      case .waitingForGame:
        WaitingView(model: model)
      case .ready:
        ReadyView(model: model, updates: updates)
      }
      Footer(model: model)
    }
    .padding(Brand.pad)
    .frame(width: Brand.width, alignment: .leading)
  }
}

// MARK: - Install

struct InstallView: View {
  @ObservedObject var model: Model

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(model.steps) { step in
          StepRow(step: step, state: state(of: step), progress: step.id == model.stepIndex ? model.progress : nil,
                  failure: step.id == failedStep ? model.failure : nil)
        }
      }
      if model.operation != nil {
        Button("Cancel") { model.cancel() }
          .controlSize(.large)
      } else if model.failure != nil {
        HStack(spacing: 12) {
          Button("Try Again") { model.run(.install) }
            .buttonStyle(PrimaryButtonStyle())
          Button("Show Logs") { model.showLogs() }
            .controlSize(.large)
        }
      } else {
        Button("Install") { model.run(.install) }
          .buttonStyle(PrimaryButtonStyle())
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  // a failure shows at the step that was running; before any step, at the first
  private var failedStep: Int { model.failure == nil ? 0 : max(model.stepIndex, 1) }

  private func state(of step: Step) -> StepState {
    if model.failure != nil {
      return step.id < failedStep ? .done : step.id == failedStep ? .failed : .pending
    }
    guard model.operation != nil else { return .pending }
    return step.id < model.stepIndex ? .done : step.id == model.stepIndex ? .current : .pending
  }
}

enum StepState { case pending, current, done, failed }

struct StepRow: View {
  let step: Step
  let state: StepState
  let progress: Model.Progress?
  let failure: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      marker
        .frame(width: 18, height: 18)
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
      VStack(alignment: .leading, spacing: 4) {
        Text(step.title)
          .foregroundStyle(state == .pending ? .secondary : .primary)
        if let failure {
          Text(failure)
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        } else if let progress {
          ProgressView(value: Double(progress.done), total: Double(progress.total))
          Text("\(megabytes(progress.done)) of \(megabytes(progress.total)) MB")
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        } else if !step.detail.isEmpty {
          Text(step.detail)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder private var marker: some View {
    switch state {
    case .pending:
      Image(systemName: "circle").foregroundStyle(.tertiary)
    case .current:
      ProgressView().controlSize(.small)
    case .done:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
        .accessibilityLabel("Done")
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        .accessibilityLabel("Failed")
    }
  }
}

func megabytes(_ bytes: Int64) -> String {
  (Double(bytes) / 1_048_576).formatted(.number.precision(.fractionLength(0)))
}

// MARK: - Waiting for Steam's download

struct WaitingView: View {
  @ObservedObject var model: Model

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Sign in to Steam and install Quake Live")
          .font(.headline)
        if let download = model.gameDownload {
          ProgressView(value: Double(download.done), total: Double(download.total))
          Text("\(megabytes(download.done)) of \(megabytes(download.total)) MB")
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        if let error = model.playError {
          Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
      }
      Button(model.stopping ? "Quitting Steam…" : model.sessionRunning ? "Show Steam" : "Open Steam") { model.showSteam() }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(model.launching || model.stopping)
    }
  }
}

// MARK: - Ready

struct ReadyView: View {
  @ObservedObject var model: Model
  @ObservedObject var updates: Updates

  var body: some View {
    VStack(alignment: .leading, spacing: 28) {
      VStack(alignment: .leading, spacing: 8) {
        Button { model.play() } label: {
          HStack(spacing: 8) {
            if busy {
              // a light spinner on the button's grey, in both appearances
              ProgressView().controlSize(.small).colorScheme(.dark)
            }
            Text(playLabel)
          }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(model.gameRunning || busy)
        .keyboardShortcut(.defaultAction)
        if model.launchStage == "update", let download = model.gameDownload {
          ProgressView(value: Double(download.done), total: Double(download.total))
          Text("\(megabytes(download.done)) of \(megabytes(download.total)) MB")
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        } else if model.launchStage == "signin" && !model.steamSignedIn {
          Text("Sign in to Steam in its window. The game starts after that.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        if let error = model.playError {
          Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        } else if let problem = model.launchProblem {
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(problem == .failed ? "Steam quit before Quake Live started." : "Quake Live hasn't started. Steam may be waiting for you.")
              .font(.callout)
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            if problem == .failed {
              Button("Show Logs") { model.showLogs() }.fixedSize()
            } else {
              Button("Show Steam") { model.showSteam() }.fixedSize()
            }
          }
        }
      }
      VStack(alignment: .leading, spacing: 18) {
        SettingRow(label: "Frame cap", hint: "Steam Cloud carries this to your other computers.") {
          Picker("Frame cap", selection: Binding(get: { model.fps }, set: { model.set("fps", String($0)) })) {
            Text("125").tag(125)
            Text("250").tag(250)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
        }
        SettingRow(label: "Retina", value: model.displayScaled ? model.resolution : nil, hint: retinaHint) {
          HStack(spacing: 12) {
            if model.retinaWaits {
              Button("Quit Steam") { model.quitSteam() }
                .fixedSize()
            }
            Toggle("Retina", isOn: Binding(get: { model.retina }, set: { model.set("retina", $0 ? "on" : "off") }))
              .toggleStyle(.switch)
              .labelsHidden()
              .disabled(!model.displayScaled)
          }
        }
        if model.steamSignedIn {
          SettingRow(label: "Steam in the background") {
            Toggle("Steam in the background", isOn: Binding(get: { model.steamInBackground }, set: { model.set("steambg", $0 ? "on" : "off") }))
              .toggleStyle(.switch)
              .labelsHidden()
          }
        }
        SettingRow(label: "Quit Steam with the game") {
          Toggle("Quit Steam with the game", isOn: Binding(get: { model.quitSteamWithGame }, set: { model.set("quitsteam", $0 ? "on" : "off") }))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        SettingRow(label: "Automatic updates", value: "Version \(updates.version)", hint: updates.available ? nil : "This build has no update feed.") {
          HStack(spacing: 12) {
            Button("Check Now") { updates.check() }
              .fixedSize()
              .disabled(!updates.available)
            Toggle("Automatic updates", isOn: Binding(get: { updates.automatic }, set: { updates.setAutomatic($0) }))
              .toggleStyle(.switch)
              .labelsHidden()
              .disabled(!updates.available)
          }
        }
      }
    }
  }

  // Play is on its way: the command runs, or Steam is somewhere between starting and the game
  private var busy: Bool { model.stopping || model.launching || model.starting }

  // The button says where a start is: with Steam in the background there is nothing else to see
  // for the half minute Steam takes to come up and sign in
  private var playLabel: String {
    if model.stopping { return "Quitting Steam…" }
    switch model.launchStage {
    case "steam": return "Starting Steam…"
    case "steamupdate": return "Steam Is Updating Itself…"
    case "signin": return model.steamSignedIn ? "Signing In to Steam…" : "Waiting for Your Steam Sign-In…"
    case "update": return "Steam Is Updating Quake Live…"
    case "game": return "Starting Quake Live…"
    default: break
    }
    if model.gameRunning { return "Quake Live Is Running" }
    return model.launching ? "Starting…" : "Play"
  }

  private var retinaHint: String? {
    if !model.displayScaled { return "This display has no Retina mode." }
    if model.retinaWaits { return "Applies after Steam quits." }
    return nil
  }
}

// One setting: its name and, quieter, its current value on the left, the control on the right,
// and a line under it only where the control alone can't say it.
struct SettingRow<Control: View>: View {
  let label: String
  var value: String? = nil
  var hint: String? = nil
  @ViewBuilder let control: () -> Control

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .center, spacing: 12) {
        Text(label)
        if let value {
          Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
        Spacer(minLength: 12)
        control()
      }
      if let hint {
        Text(hint).font(.callout).foregroundStyle(.secondary)
      }
    }
  }
}

// MARK: - Footer

struct Footer: View {
  @ObservedObject var model: Model

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Text("Unofficial. Not made or supported by id Software or Bethesda.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 12)
      if model.phase == .ready || model.phase == .waitingForGame {
        Menu("More") {
          Button(model.sessionRunning ? "Show Steam" : "Open Steam") { model.showSteam() }
          if model.sessionRunning {
            Button("Quit Steam") { model.quitSteam() }
              .disabled(model.stopping)
          }
          Button("Show Logs") { model.showLogs() }
          Divider()
          Button("Repair") { model.run(.repair) }
            .disabled(model.sessionRunning)
          Button("Uninstall…") { model.confirmUninstall() }
        }
        .fixedSize()
      }
    }
  }
}
