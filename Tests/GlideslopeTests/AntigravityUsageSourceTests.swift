import Foundation
import Testing
@testable import Glideslope

@Suite("Antigravity quota source and cache migration")
struct AntigravityUsageSourceTests {
  private let oldEndpoint = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("default endpoint matches the native Antigravity backend")
  func defaultBackend() {
    #expect(AntigravityUsageSource.url(environment: [:]).absoluteString
      == "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")
  }

  @Test("supported endpoint overrides change the stable cache identity")
  func overrideIdentity() {
    let environment = ["GLIDESLOPE_ANTIGRAVITY_USAGE_URL": oldEndpoint]
    #expect(AntigravityUsageSource.url(environment: environment).absoluteString == oldEndpoint)
    #expect(AntigravityUsageSource.cacheIdentity(environment: environment)
      != AntigravityUsageSource.cacheIdentity(environment: [:]))
    #expect(AntigravityUsageSource.cacheIdentity(environment: [:])
      == AntigravityUsageSource.cacheIdentity(environment: [:]))
  }

  @Test("source identifiers contain no private endpoint text")
  func privateEndpointText() {
    let identity = AntigravityUsageSource.cacheIdentity(environment: [
      "GLIDESLOPE_ANTIGRAVITY_USAGE_URL": "https://user:private@example.invalid/quota?token=private"
    ])
    #expect(identity.count == 64)
    #expect(identity.allSatisfy { "0123456789abcdef".contains($0) })
    #expect(!identity.contains("private"))
  }

  @Test("legacy Antigravity readings are dropped while Codex and Claude survive")
  func legacyMigration() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "usage-cache.json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var readings: [String: Any] = [:]
    for provider in [Provider.antigravity, .codex, .claude] {
      readings[provider.rawValue] = [
        "capturedAt": ISO8601DateFormatter().string(from: now),
        "windows": try JSONSerialization.jsonObject(with: encoder.encode([window(provider)]))
      ]
    }
    try JSONSerialization.data(withJSONObject: ["version": 1, "readings": readings]).write(to: url)
    var cache = UsageResultCache(persistenceURL: url)
    #expect(cache.cacheAge(for: .antigravity, now: now) == nil)
    #expect(!cache.reconcile(failure(.antigravity), now: now).ok)
    #expect(cache.reconcile(failure(.codex), now: now).source == "cached")
    #expect(cache.reconcile(failure(.claude), now: now).source == "cached")
    #expect(cache.reconcile(live(.antigravity), now: now).source == "live")
    var restored = UsageResultCache(persistenceURL: url)
    #expect(restored.reconcile(failure(.antigravity), now: now).source == "cached")
    #expect(restored.reconcile(failure(.codex), now: now).source == "cached")
  }

  @Test("switching endpoints in either direction invalidates only Antigravity")
  func endpointSwitch() throws {
    let current = AntigravityUsageSource.cacheIdentity(environment: [:])
    let old = AntigravityUsageSource.cacheIdentity(environment: ["GLIDESLOPE_ANTIGRAVITY_USAGE_URL": oldEndpoint])
    for (firstIdentity, secondIdentity) in [(old, current), (current, old)] {
      let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let url = directory.appending(path: "usage-cache.json")
      var first = UsageResultCache(persistenceURL: url, antigravitySourceIdentity: firstIdentity)
      _ = first.reconcile(live(.antigravity), now: now)
      _ = first.reconcile(live(.claude), now: now)
      var second = UsageResultCache(persistenceURL: url, antigravitySourceIdentity: secondIdentity)
      #expect(!second.reconcile(failure(.antigravity), now: now).ok)
      #expect(second.reconcile(failure(.claude), now: now).source == "cached")
      #expect(second.cacheAge(for: .antigravity, now: now) == nil)
    }
  }

  @Test("same-source readings remain usable and reset-bounded through errors")
  func sameSourceFallback() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "usage-cache.json")
    let identity = AntigravityUsageSource.cacheIdentity(environment: [:])
    var first = UsageResultCache(persistenceURL: url, antigravitySourceIdentity: identity)
    _ = first.reconcile(live(.antigravity), now: now)
    var second = UsageResultCache(persistenceURL: url, antigravitySourceIdentity: identity)
    let cached = second.reconcile(failure(.antigravity), now: now.addingTimeInterval(30))
    #expect(cached.ok && cached.source == "cached")
    #expect(cached.cacheAgeSeconds == 30)
    #expect(cached.windows.first?.usedPercent == 75)
    let stored = try String(contentsOf: url, encoding: .utf8)
    #expect(stored.contains(identity))
    #expect(!stored.contains("googleapis.com"))
    #expect(!second.reconcile(failure(.antigravity), now: now.addingTimeInterval(24 * 3_600)).ok)
  }

  private func window(_ provider: Provider) -> UsageWindow {
    PressureMath.window(provider: provider, speed: .slow, usedPercent: 75,
      resetAt: now.addingTimeInterval(24 * 3_600), limitWindowSeconds: 7 * 24 * 3_600, now: now)
  }
  private func live(_ provider: Provider) -> ProviderResult {
    ProviderResult(provider: provider, ok: true, source: "live", error: nil, windows: [window(provider)])
  }
  private func failure(_ provider: Provider) -> ProviderResult {
    ProviderResult.failure(provider, source: "error", error: "temporary endpoint failure")
  }
}
