import Foundation
import Testing
@testable import Alight

@Suite("Migration notice")
struct MigrationNoticeTests {
  @Test("detects legacy non-secret state without reading credential bytes")
  func detectsLegacyState() throws {
    let home = URL(filePath: NSTemporaryDirectory()).appending(path: "alight-migration-\(UUID().uuidString)")
    let cache = home.appending(path: "Library/Application Support/Glideslope/usage-cache.json")
    try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("derived-cache".utf8).write(to: cache)
    defer { try? FileManager.default.removeItem(at: home) }

    let defaults = try #require(UserDefaults(suiteName: "AlightMigrationNoticeTests-legacy-\(UUID().uuidString)"))
    #expect(AlightMigrationNotice.hasLegacyData(
      homeURL: home,
      userDefaults: defaults,
      legacyDomain: "AlightMigrationNoticeTests-legacy-domain-\(UUID().uuidString)"
    ))
  }

  @Test("detects legacy CLI state and settings")
  func detectsLegacyCLIStateAndSettings() throws {
    let home = URL(filePath: NSTemporaryDirectory()).appending(path: "alight-migration-cli-\(UUID().uuidString)")
    let cliState = home.appending(path: ".codex-usage-pressure/state.json")
    try FileManager.default.createDirectory(at: cliState.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}\n".utf8).write(to: cliState)
    defer { try? FileManager.default.removeItem(at: home) }

    let suite = "AlightMigrationNoticeTests-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let legacyDomain = "AlightMigrationNoticeTests-settings-domain-\(UUID().uuidString)"
    defaults.setPersistentDomain(["refreshInterval": 60], forName: legacyDomain)
    defer { defaults.removePersistentDomain(forName: legacyDomain) }

    #expect(AlightMigrationNotice.hasLegacyData(homeURL: home, userDefaults: defaults))
  }

  @Test("does not report a fresh home as legacy state")
  func freshHomeHasNoLegacyState() {
    let home = URL(filePath: NSTemporaryDirectory()).appending(path: "alight-migration-empty-\(UUID().uuidString)")
    let defaults = UserDefaults(suiteName: "AlightMigrationNoticeTests-empty-\(UUID().uuidString)")!
    #expect(!AlightMigrationNotice.hasLegacyData(
      homeURL: home,
      userDefaults: defaults,
      legacyDomain: "AlightMigrationNoticeTests-empty-domain-\(UUID().uuidString)"
    ))
  }
}
