import AppKit
@preconcurrency import Sparkle

/// Owns Alight's single canonical software-update path.
///
/// Sparkle verifies update archives with the Ed25519 public key embedded in the
/// app bundle. That signature remains the update identity while alpha builds
/// are ad-hoc signed, and it can authenticate a later release that adds Apple
/// Developer ID signing and notarization without changing this API surface.
@MainActor
final class AppUpdater: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
  private lazy var controller = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: self
  )

  /// Alight has no Dock presence, so update alerts that need attention must
  /// temporarily promote the app instead of appearing silently behind another
  /// application. Fully automatic installs normally never take this path.
  var supportsGentleScheduledUpdateReminders: Bool {
    true
  }

  var canCheckForUpdates: Bool {
    controller.updater.canCheckForUpdates
  }

  var automaticallyInstallsUpdates: Bool {
    controller.updater.automaticallyDownloadsUpdates
  }

  func checkForUpdates() {
    controller.checkForUpdates(nil)
  }

  func setAutomaticallyInstallsUpdates(_ enabled: Bool) {
    // Opting out changes installation behavior, not the notification channel.
    // Scheduled checks continue so manual-mode users still learn about releases.
    controller.updater.automaticallyDownloadsUpdates = enabled
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    if handleShowingUpdate {
      NSApp.setActivationPolicy(.regular)
    }
  }

  func standardUserDriverWillFinishUpdateSession() {
    NSApp.setActivationPolicy(.accessory)
  }
}
