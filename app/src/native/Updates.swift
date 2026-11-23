// App updates: Sparkle with its own standard window. A build has updates only when its Info.plist
// names a feed (SUFeedURL, set by build.zsh from QL_ON_MAC_FEED_URL with the feed's public key);
// without one Sparkle is never started and the window says so. Installing always takes a click.

import AppKit
import Sparkle
import SwiftUI

@MainActor
final class Updates: ObservableObject {
  static let appBundleID = "cz.jandrly.qlonmac"

  @Published var automatic = false
  let version: String
  private var controller: SPUStandardUpdaterController?
  private let previewAvailable: Bool

  init() {
    let app = Bundle.main
    version = app.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    previewAvailable = false
    let feed = app.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
    guard app.bundleIdentifier == Updates.appBundleID, !feed.isEmpty else {
      NSLog("\(appName): this build has no update feed. Updates are off.")
      return
    }
    let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    self.controller = controller
    automatic = controller.updater.automaticallyChecksForUpdates
  }

  // A fixed state for the headless render
  init(previewVersion: String, available: Bool, automatic: Bool) {
    version = previewVersion
    previewAvailable = available
    self.automatic = automatic
  }

  var available: Bool { controller != nil || previewAvailable }

  func setAutomatic(_ on: Bool) {
    controller?.updater.automaticallyChecksForUpdates = on
    automatic = on
  }

  func check() { controller?.checkForUpdates(nil) }
}
