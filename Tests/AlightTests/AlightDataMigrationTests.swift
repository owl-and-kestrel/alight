import Foundation
import Testing
@testable import Alight

@Suite("Alight data migration")
struct AlightDataMigrationTests {
  @Test("imports valid cache and allowlisted settings without overwriting")
  func importsOnceAndPreservesSource() throws {
    let home = URL(filePath: NSTemporaryDirectory()).appending(path: "alight-data-\(UUID().uuidString)")
    let oldCache = home.appending(path: "Library/Application Support/Glideslope/usage-cache.json")
    let newCache = home.appending(path: "Library/Application Support/Alight/usage-cache.json")
    try FileManager.default.createDirectory(at: oldCache.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let window = PressureMath.window(
      provider: .codex,
      speed: .fast,
      usedPercent: 20,
      resetAt: capturedAt.addingTimeInterval(3_600),
      limitWindowSeconds: 5 * 3_600,
      now: capturedAt
    )
    var oldCacheWriter = UsageResultCache(persistenceURL: oldCache)
    _ = oldCacheWriter.reconcile(
      ProviderResult(provider: .codex, ok: true, source: "live", error: nil, windows: [window]),
      now: capturedAt
    )
    let cache = try String(contentsOf: oldCache, encoding: .utf8)

    let suite = "AlightDataMigrationTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let legacyDomain = "AlightDataMigrationTests-legacy-domain-\(UUID().uuidString)"
    defaults.setPersistentDomain([
      "codexColor": "mint",
      "fastHandWidth": 3.0,
      "credential": "must-not-copy"
    ], forName: legacyDomain)
    defer {
      defaults.removePersistentDomain(forName: suite)
      defaults.removePersistentDomain(forName: legacyDomain)
    }

    let result = AlightDataMigration.apply(
      homeURL: home,
      userDefaults: defaults,
      destinationDomain: suite,
      legacyDomain: legacyDomain
    )
    #expect(result.cacheImported)
    #expect(result.settingsImported.contains("codexColor"))
    #expect(result.settingsImported.contains("fastHandWidth"))
    #expect(defaults.persistentDomain(forName: suite)?["credential"] == nil)
    #expect(defaults.object(forKey: "codexColor") as? String == "mint")
    #expect(FileManager.default.fileExists(atPath: newCache.path))
    #expect(try Data(contentsOf: oldCache) == Data(cache.utf8))

    let replay = AlightDataMigration.apply(
      homeURL: home,
      userDefaults: defaults,
      destinationDomain: suite,
      legacyDomain: legacyDomain
    )
    #expect(!replay.cacheImported)
    #expect(try Data(contentsOf: newCache) == Data(cache.utf8))

    try FileManager.default.removeItem(at: newCache)
    try FileManager.default.removeItem(at: newCache.deletingLastPathComponent())
    let outside = home.appending(path: "outside", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: newCache.deletingLastPathComponent(),
      withDestinationURL: outside
    )
    let symlinkAttempt = AlightDataMigration.apply(
      homeURL: home,
      userDefaults: defaults,
      destinationDomain: suite,
      legacyDomain: legacyDomain
    )
    #expect(!symlinkAttempt.cacheImported)
    #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "usage-cache.json").path))
  }
}
