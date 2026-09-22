import AppKit
import OSLog

/// Finishes the Glideslope → Alight rename for installations that arrived via
/// the old Sparkle feed.
///
/// Sparkle installs an update into the host's existing path and locates the
/// app inside the archive by the host's file name, so the bridge archive on
/// the Glideslope feed ships this app as `Glideslope.app`. After that update
/// relaunches, we are Alight (bundle `com.owlandkestrel.alight`, Alight feed)
/// living at `…/Glideslope.app`. Renaming the bundle on disk gives the user an
/// `Alight.app` and keeps later archives matching by file name as well as by
/// bundle identifier. Login items are bookmark-based and follow the rename.
///
/// The rename is best-effort: if the destination exists or the directory is
/// not writable, the app keeps running from the old name. Later Alight updates
/// still apply, because Sparkle also matches the archive's app by bundle id.
enum BridgeRelocation {
  static let legacyBundleName = "Glideslope.app"
  static let bundleName = "Alight.app"

  private static let logger = Logger(subsystem: "com.owlandkestrel.alight", category: "bridge")

  /// The destination for a bundle that still carries the legacy name, or nil
  /// when no rename is needed or it cannot be done safely.
  static func relocationTarget(
    bundleURL: URL,
    fileExists: (String) -> Bool,
    isWritableDirectory: (String) -> Bool
  ) -> URL? {
    guard bundleURL.lastPathComponent.caseInsensitiveCompare(legacyBundleName) == .orderedSame else {
      return nil
    }
    let directory = bundleURL.deletingLastPathComponent()
    let target = directory.appending(path: bundleName)
    guard !fileExists(target.path), isWritableDirectory(directory.path) else {
      return nil
    }
    return target
  }

  /// Renames the running bundle and relaunches from the new path. Returns
  /// true when a relaunch was started and the caller should stop launching.
  @MainActor
  static func relocateIfNeeded(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
    let fileManager = FileManager.default
    guard let target = relocationTarget(
      bundleURL: bundleURL,
      fileExists: { fileManager.fileExists(atPath: $0) },
      isWritableDirectory: { fileManager.isWritableFile(atPath: $0) }
    ) else {
      return false
    }

    do {
      try fileManager.moveItem(at: bundleURL, to: target)
    } catch {
      logger.error("Bridge rename failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
    logger.info("Bridge rename completed to \(target.lastPathComponent, privacy: .public)")

    // `open -n` starts a fresh instance from the new path; the old process
    // exits right after so only one status item is ever shown.
    let relaunch = Process()
    relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    relaunch.arguments = ["-n", target.path]
    do {
      try relaunch.run()
    } catch {
      logger.error("Bridge relaunch failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
    return true
  }
}
