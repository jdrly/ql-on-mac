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
      Button(model.sessionRunning ? "Show Steam" : "Open Steam") { model.showSteam() }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(model.launching)
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
        Button(model.gameRunning ? "Quake Live Is Running" : model.launching ? "Starting…" : "Play") { model.play() }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(model.gameRunning || model.launching)
          .keyboardShortcut(.defaultAction)
        if let error = model.playError {
          Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
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
