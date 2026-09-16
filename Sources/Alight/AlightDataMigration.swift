import Foundation

/// Performs the one-time, non-secret part of the Glideslope to Alight move.
///
/// The destination is never overwritten. Provider credentials stay in their
/// provider-owned Keychain or token files and are intentionally outside this
/// helper's allowlist.
enum AlightDataMigration {
  static let legacyDefaultsDomain = "com.owlandkestrel.glideslope"
  static let destinationDefaultsDomain = "com.owlandkestrel.alight"

  struct Result: Sendable {
    let cacheImported: Bool
    let settingsImported: [String]
  }

  static func hasLegacyData(
    homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default,
    userDefaults: UserDefaults = .standard,
    legacyDomain: String = legacyDefaultsDomain
  ) -> Bool {
    fileManager.fileExists(atPath: legacyCacheURL(homeURL: homeURL).path)
      || !(userDefaults.persistentDomain(forName: legacyDomain)?.isEmpty ?? true)
  }

  static func apply(
    homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default,
    userDefaults: UserDefaults = .standard,
    destinationDomain: String = destinationDefaultsDomain,
    legacyDomain: String = legacyDefaultsDomain
  ) -> Result {
    let cacheImported = importCache(homeURL: homeURL, fileManager: fileManager)
    let settingsImported = importSettings(
      userDefaults: userDefaults,
      legacyDomain: legacyDomain,
      destinationDomain: destinationDomain
    )
    return Result(cacheImported: cacheImported, settingsImported: settingsImported)
  }

  private static func legacyCacheURL(
    homeURL: URL
  ) -> URL {
    homeURL
      .appending(path: "Library/Application Support/Glideslope/usage-cache.json")
  }

  private static func destinationCacheURL(
    homeURL: URL
  ) -> URL {
    homeURL
      .appending(path: "Library/Application Support/Alight/usage-cache.json")
  }

  private static func importCache(homeURL: URL, fileManager: FileManager) -> Bool {
    let source = legacyCacheURL(homeURL: homeURL)
    let destination = destinationCacheURL(homeURL: homeURL)
    guard fileManager.fileExists(atPath: source.path),
          !fileManager.fileExists(atPath: destination.path),
          !isSymlink(source, fileManager: fileManager),
          !isSymlink(destination.deletingLastPathComponent(), fileManager: fileManager),
          UsageResultCache.isValidPersistedCache(at: source) else {
      return false
    }

    do {
      let directory = destination.deletingLastPathComponent()
      try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try fileManager.copyItem(at: source, to: destination)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
      return true
    } catch {
      return false
    }
  }

  private static func isSymlink(_ url: URL, fileManager: FileManager) -> Bool {
    (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
  }

  private static func importSettings(
    userDefaults: UserDefaults,
    legacyDomain: String,
    destinationDomain: String
  ) -> [String] {
    guard let source = userDefaults.persistentDomain(forName: legacyDomain) else {
      return []
    }

    let allowedKeys = Set(IconSliderSetting.allCases.map(\.rawValue) + [
      "codexColor", "claudeColor", "antigravityColor", "redlineColor"
    ])
    var destination = userDefaults.persistentDomain(forName: destinationDomain) ?? [:]
    var imported: [String] = []
    for key in allowedKeys.sorted() {
      guard let value = source[key], isAllowed(value, key: key),
            destination[key] == nil,
            userDefaults.object(forKey: key) == nil else {
        continue
      }
      destination[key] = value
      imported.append(key)
    }
    if !imported.isEmpty {
      userDefaults.setPersistentDomain(destination, forName: destinationDomain)
    }
    return imported
  }

  private static func isAllowed(_ value: Any, key: String) -> Bool {
    if key.hasSuffix("Color") {
      guard let raw = value as? String else { return false }
      return GaugeColorChoice(rawValue: raw) != nil
    }
    guard let number = value as? NSNumber else { return false }
    return number.doubleValue.isFinite
  }
}
