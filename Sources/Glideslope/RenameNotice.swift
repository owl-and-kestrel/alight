import AppKit

/// Announces the Alight rename from the last Glideslope identity.
///
/// This code deliberately stays in the historical Glideslope target. Sparkle
/// can deliver this build to Glideslope users because its bundle id and feed
/// remain unchanged; the button only opens the Alight page for a user to
/// install manually. It never asks Sparkle to install a different bundle.
enum GlideslopeRenameNotice {
  static let markerKey = "GlideslopeAlightRenameNoticeV1"
  static let alightURL = URL(string: "https://owlandkestrel.com/apps/alight")!

  static func shouldPresent(userDefaults: UserDefaults = .standard) -> Bool {
    !userDefaults.bool(forKey: markerKey)
  }

  @MainActor
  static func presentIfNeeded(userDefaults: UserDefaults = .standard) {
    guard shouldPresent(userDefaults: userDefaults) else { return }

    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = "Glideslope is now Alight"
    alert.informativeText = "Glideslope is now Alight. Download Alight to keep getting improvements. Your settings can be brought across when you open it. You may need to open Codex, Claude Code, or Antigravity once so Alight can see your existing sign-in."
    alert.addButton(withTitle: "Download Alight")
    alert.addButton(withTitle: "Later")
    if alert.runModal() == .alertFirstButtonReturn {
      _ = NSWorkspace.shared.open(alightURL)
    }

    userDefaults.set(true, forKey: markerKey)
    NSApp.setActivationPolicy(.accessory)
  }
}
