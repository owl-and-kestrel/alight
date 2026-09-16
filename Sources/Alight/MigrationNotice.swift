import AppKit

/// Offers the one-time local-data choice required by the bundle-identifier
/// change. The native choice runs before the status item creates new state;
/// command-line state remains an explicit operator migration.
enum AlightMigrationNotice {
  static let markerName = ".alight-migration-notice-v1"

  static func hasLegacyData(
    homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default,
    userDefaults: UserDefaults = .standard,
    legacyDomain: String = AlightDataMigration.legacyDefaultsDomain
  ) -> Bool {
    let legacyCLIState = homeURL.appending(path: ".codex-usage-pressure/state.json")
    return AlightDataMigration.hasLegacyData(
      homeURL: homeURL,
      fileManager: fileManager,
      userDefaults: userDefaults,
      legacyDomain: legacyDomain
    ) || fileManager.fileExists(atPath: legacyCLIState.path)
  }

  @MainActor
  static func presentIfNeeded(
    fileManager: FileManager = .default,
    userDefaults: UserDefaults = .standard
  ) {
    let marker = fileManager.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support/Alight")
      .appending(path: markerName)
    guard !fileManager.fileExists(atPath: marker.path),
          hasLegacyData(
            homeURL: fileManager.homeDirectoryForCurrentUser,
            fileManager: fileManager,
            userDefaults: userDefaults
          ) else { return }

    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Glideslope is now Alight"
    alert.informativeText = "Your previous settings and usage display can be brought across. Import settings to keep them, or start fresh. Provider sign-ins stay on your computer; you may need to open Codex, Claude Code, or Antigravity once so Alight can see them."
    alert.addButton(withTitle: "Import Settings")
    alert.addButton(withTitle: "Start Fresh")
    alert.addButton(withTitle: "Later")
    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
      _ = AlightDataMigration.apply(fileManager: fileManager, userDefaults: userDefaults)
    }
    NSApp.setActivationPolicy(.accessory)

    // Keep the prompt available after Later or window dismissal so an owner
    // can make the import choice once the old app has been closed.
    if response == .alertFirstButtonReturn || response == .alertSecondButtonReturn {
      do {
        try fileManager.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("shown\n".utf8).write(to: marker, options: .atomic)
      } catch {
        // A failed marker write must not attempt migration or change runtime
        // settings; a later launch may show the notice again.
      }
    }
  }
}
