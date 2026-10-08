import Foundation
import Testing
@testable import Alight

@Suite("Usage result cache")
struct UsageResultCacheTests {
  private static let account = ClaudeAuthStatus.observationIdentity(
    email: "person@example.com", orgId: "org-1", subscriptionType: "max")!
  private static let otherAccount = ClaudeAuthStatus.observationIdentity(
    email: "someone@example.com", orgId: "org-1", subscriptionType: "max")!

  private func claudeLive(_ windows: [UsageWindow], identity: UsageObservationIdentity? = Self.account) -> ProviderResult {
    ProviderResult(provider: .claude, ok: true, source: "live", error: nil, windows: windows, observationIdentity: identity)
  }

  private func claudeFailure(_ error: String = "usage fetch failed", source: String = "error", needsAuth: Bool = false,
    identity: UsageObservationIdentity? = Self.account) -> ProviderResult {
    .failure(.claude, source: source, error: error, needsAuth: needsAuth, observationIdentity: identity)
  }

  @Test("a cached reading older than maxCacheAge is dropped even before its reset")
  func staleCacheIsDroppedAfterMaxAge() {
    let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let resetAt = capturedAt.addingTimeInterval(7 * 24 * 3_600)
    let window = makeWindow(
      provider: .claude, speed: .slow, usedPercent: 7,
      resetAt: resetAt, duration: 7 * 24 * 3_600, now: capturedAt
    )
    var cache = UsageResultCache(persistenceURL: nil)
    _ = cache.reconcile(claudeLive([window]), now: capturedAt)
    let failure = claudeFailure()

    let fresh = cache.reconcile(
      failure, now: capturedAt.addingTimeInterval(UsageResultCache.maxCacheAge - 60))
    #expect(fresh.source == "cached")
    #expect(fresh.windows.count == 1)

    let stale = cache.reconcile(
      failure, now: capturedAt.addingTimeInterval(UsageResultCache.maxCacheAge + 60))
    #expect(!stale.ok)
    #expect(stale.windows.isEmpty)
    #expect(stale.error?.contains("last live 6h ago") == true)
  }

  @Test("the six-hour limit applies to every provider's cache")
  func staleCodexCacheIsDroppedAfterMaxAge() {
    let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let window = makeWindow(
      provider: .codex, speed: .slow, usedPercent: 7,
      resetAt: capturedAt.addingTimeInterval(7 * 24 * 3_600), duration: 7 * 24 * 3_600, now: capturedAt
    )
    var cache = UsageResultCache(persistenceURL: nil)
    _ = cache.reconcile(ProviderResult(provider: .codex, ok: true, source: "live", error: nil, windows: [window]), now: capturedAt)
    let stale = cache.reconcile(.failure(.codex, source: "error", error: "usage fetch failed"),
      now: capturedAt.addingTimeInterval(UsageResultCache.maxCacheAge + 1))
    #expect(!stale.ok)
    #expect(stale.windows.isEmpty)
  }

  @Test("Claude readings are reused only for the same verified account")
  func claudeCacheIsBoundToAccount() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cacheURL = directory.appending(path: "usage-cache.json")
    let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let window = makeWindow(provider: .claude, speed: .fast, usedPercent: 30,
      resetAt: capturedAt.addingTimeInterval(3_600), duration: 5 * 3_600, now: capturedAt)

    var first = UsageResultCache(persistenceURL: cacheURL)
    _ = first.reconcile(claudeLive([window]), now: capturedAt)
    let persisted = try String(contentsOf: cacheURL, encoding: .utf8)
    #expect(persisted.contains(Self.account.accountPartition))
    #expect(!persisted.localizedCaseInsensitiveContains("example"))

    // Same account after a relaunch: the reading stands in, with its identity.
    var relaunched = UsageResultCache(persistenceURL: cacheURL)
    let same = relaunched.reconcile(claudeFailure(), now: capturedAt.addingTimeInterval(60))
    #expect(same.source == "cached")
    #expect(same.observationIdentity == Self.account)

    // A different login drops it, and it stays dropped.
    let switched = relaunched.reconcile(claudeFailure(identity: Self.otherAccount), now: capturedAt.addingTimeInterval(120))
    #expect(!switched.ok)
    #expect(switched.windows.isEmpty)
    #expect(switched.cacheAgeSeconds == nil)
    var afterSwitch = UsageResultCache(persistenceURL: cacheURL)
    #expect(afterSwitch.reconcile(claudeFailure(), now: capturedAt.addingTimeInterval(180)).windows.isEmpty)
  }

  @Test("an unknown Claude account drops the cache, and unidentified readings are never cached")
  func unknownClaudeAccount() {
    let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let window = makeWindow(provider: .claude, speed: .fast, usedPercent: 30,
      resetAt: capturedAt.addingTimeInterval(3_600), duration: 5 * 3_600, now: capturedAt)
    var cache = UsageResultCache(persistenceURL: nil)
    _ = cache.reconcile(claudeLive([window]), now: capturedAt)

    let signedOut = cache.reconcile(
      claudeFailure("not signed in to Claude Code", needsAuth: true, identity: nil),
      now: capturedAt.addingTimeInterval(60))
    #expect(!signedOut.ok)
    #expect(signedOut.needsAuth)
    #expect(signedOut.windows.isEmpty)
    #expect(cache.cacheAge(for: .claude, now: capturedAt) == nil)

    let unidentified = cache.reconcile(claudeLive([window], identity: nil), now: capturedAt.addingTimeInterval(120))
    #expect(unidentified.ok && unidentified.source == "live")
    #expect(cache.cacheAge(for: .claude, now: capturedAt) == nil)
    #expect(cache.reconcile(claudeFailure(source: "deferred", identity: nil), now: capturedAt.addingTimeInterval(180)).windows.isEmpty)
  }

  @Test("unbound Claude readings from earlier versions are ignored on load")
  func legacyUnboundClaudeReadingIsDropped() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cacheURL = directory.appending(path: "usage-cache.json")
    let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let window = makeWindow(provider: .claude, speed: .slow, usedPercent: 7,
      resetAt: capturedAt.addingTimeInterval(24 * 3_600), duration: 7 * 24 * 3_600, now: capturedAt)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let legacy: [String: Any] = ["version": 1, "readings": ["claude": [
      "capturedAt": ISO8601DateFormatter().string(from: capturedAt),
      "windows": try JSONSerialization.jsonObject(with: encoder.encode([window])),
    ]]]
    try JSONSerialization.data(withJSONObject: legacy).write(to: cacheURL)

    var cache = UsageResultCache(persistenceURL: cacheURL)
    #expect(cache.cacheAge(for: .claude, now: capturedAt) == nil)
    #expect(cache.reconcile(claudeFailure(), now: capturedAt.addingTimeInterval(60)).windows.isEmpty)
  }

  @Test("auth failures keep and rebase persisted last-known windows")
  func authFailureKeepsPersistedLastKnownWindowAndRebasesPressure() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cacheURL = directory.appending(path: "usage-cache.json")
    let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let resetAt = capturedAt.addingTimeInterval(3_600)
    let liveWindow = makeWindow(
      provider: .claude,
      speed: .fast,
      usedPercent: 30,
      resetAt: resetAt,
      duration: 5 * 3_600,
      now: capturedAt
    )

    var firstProcess = UsageResultCache(persistenceURL: cacheURL)
    let live = claudeLive([liveWindow])
    #expect(firstProcess.reconcile(live, now: capturedAt).source == "live")

    var relaunchedProcess = UsageResultCache(persistenceURL: cacheURL)
    let checkedAt = capturedAt.addingTimeInterval(600)
    // A failed /usage run for the same, still signed-in account.
    let authFailure = claudeFailure("Claude Code /usage failed", needsAuth: true)
    let cached = relaunchedProcess.reconcile(authFailure, now: checkedAt)

    #expect(cached.ok)
    #expect(cached.source == "cached")
    #expect(cached.error == "Claude Code /usage failed")
    #expect(cached.needsAuth)
    #expect(cached.cacheAgeSeconds == 600)
    #expect(cached.windows.count == 1)
    #expect(cached.windows[0].pressurePercent != liveWindow.pressurePercent)
    let expectedPressure = makeWindow(
      provider: .claude,
      speed: .fast,
      usedPercent: 30,
      resetAt: resetAt,
      duration: 5 * 3_600,
      now: checkedAt
    ).pressurePercent
    #expect(abs(cached.windows[0].pressurePercent - expectedPressure) < 0.001)

    let persisted = try String(contentsOf: cacheURL, encoding: .utf8)
    #expect(persisted.contains("usedPercent"))
    #expect(!persisted.localizedCaseInsensitiveContains("token"))
  }

  @Test("expired windows retire independently")
  func expiredWindowRetiresIndependentlyWhileLongWindowSurvives() {
    let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var cache = UsageResultCache(persistenceURL: nil)
    let fast = makeWindow(
      provider: .claude,
      speed: .fast,
      usedPercent: 40,
      resetAt: capturedAt.addingTimeInterval(300),
      duration: 5 * 3_600,
      now: capturedAt
    )
    let weekly = makeWindow(
      provider: .claude,
      speed: .slow,
      usedPercent: 50,
      resetAt: capturedAt.addingTimeInterval(7_200),
      duration: 7 * 24 * 3_600,
      now: capturedAt
    )
    _ = cache.reconcile(
      claudeLive([fast, weekly]),
      now: capturedAt
    )

    let cached = cache.reconcile(
      claudeFailure(),
      now: capturedAt.addingTimeInterval(600)
    )

    #expect(cached.ok)
    #expect(cached.windows.map(\.speed) == [.slow])
  }

  @Test("all expired windows return a failure and purge the cache")
  func allExpiredWindowsReturnFailureAndArePurged() {
    let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var cache = UsageResultCache(persistenceURL: nil)
    let fast = makeWindow(
      provider: .claude,
      speed: .fast,
      usedPercent: 70,
      resetAt: capturedAt.addingTimeInterval(60),
      duration: 5 * 3_600,
      now: capturedAt
    )
    _ = cache.reconcile(
      claudeLive([fast]),
      now: capturedAt
    )

    let failure = cache.reconcile(
      claudeFailure("Claude Code /usage timed out"),
      now: capturedAt.addingTimeInterval(120)
    )
    #expect(!failure.ok)
    #expect(failure.windows.isEmpty)
    #expect(failure.error?.contains("last live 2m ago") == true)

    let afterPurge = cache.reconcile(
      claudeFailure("still unavailable"),
      now: capturedAt.addingTimeInterval(180)
    )
    #expect(afterPurge.error == "still unavailable")
    #expect(afterPurge.cacheAgeSeconds == nil)
  }

  @Test("a later authoritative success clears an absent scoped limit")
  func authoritativeSuccessClearsAbsentScopedLimit() {
    let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let resetAt = capturedAt.addingTimeInterval(7_200)
    var cache = UsageResultCache(persistenceURL: nil)
    let fast = makeWindow(
      provider: .claude,
      speed: .fast,
      usedPercent: 20,
      resetAt: resetAt,
      duration: 5 * 3_600,
      now: capturedAt
    )
    let weekly = makeWindow(
      provider: .claude,
      speed: .slow,
      usedPercent: 30,
      resetAt: resetAt,
      duration: 7 * 24 * 3_600,
      now: capturedAt
    )
    let fable = PressureMath.window(
      provider: .claude,
      speed: .slow,
      usedPercent: 60,
      resetAt: resetAt,
      limitWindowSeconds: 7 * 24 * 3_600,
      now: capturedAt,
      scope: .fable,
      visualStyle: .outerStar
    )
    _ = cache.reconcile(
      claudeLive([fast, weekly, fable]),
      now: capturedAt
    )

    let authoritative = cache.reconcile(
      claudeLive([fast, weekly]),
      now: capturedAt.addingTimeInterval(60)
    )

    #expect(authoritative.windows.count == 2)
    #expect(!authoritative.windows.contains { $0.scope == .fable })
  }

  @Test("corrupt persistence is ignored")
  func corruptPersistenceFileIsIgnored() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cacheURL = directory.appending(path: "usage-cache.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(to: cacheURL)

    var cache = UsageResultCache(persistenceURL: cacheURL)
    let failure = cache.reconcile(
      .failure(.claude, source: "error", error: "unavailable"),
      now: Date(timeIntervalSince1970: 1_800_000_000)
    )

    #expect(!failure.ok)
    #expect(failure.error == "unavailable")
  }

  @Test("cached Codex windows repair old positional cadence")
  func cachedCodexWindowRepairsOldPositionalCadence() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cacheURL = directory.appending(path: "usage-cache.json")
    let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let resetAt = capturedAt.addingTimeInterval(3 * 24 * 3_600)
    let historicallyMisclassified = makeWindow(
      provider: .codex,
      speed: .fast,
      usedPercent: 10,
      resetAt: resetAt,
      duration: 7 * 24 * 3_600,
      now: capturedAt
    )

    var firstProcess = UsageResultCache(persistenceURL: cacheURL)
    _ = firstProcess.reconcile(
      ProviderResult(
        provider: .codex,
        ok: true,
        source: "live",
        error: nil,
        windows: [historicallyMisclassified]
      ),
      now: capturedAt
    )

    var relaunchedProcess = UsageResultCache(persistenceURL: cacheURL)
    let cached = relaunchedProcess.reconcile(
      .failure(.codex, source: "error", error: "usage fetch failed"),
      now: capturedAt.addingTimeInterval(60)
    )

    #expect(cached.windows.count == 1)
    #expect(cached.windows[0].speed == .slow)
    #expect(cached.windows[0].label == "Weekly")
    #expect(cached.windows[0].id == "codex_slow")
  }

  @Test("cached scoped menu rows survive failures with disclosed age")
  func scopedMenuRowsSurviveFailuresWithDisclosedAge() {
    let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var cache = UsageResultCache(persistenceURL: nil)
    let resetAt = capturedAt.addingTimeInterval(7_200)
    let fast = makeWindow(
      provider: .claude,
      speed: .fast,
      usedPercent: 20,
      resetAt: resetAt,
      duration: 5 * 3_600,
      now: capturedAt
    )
    let sonnet = PressureMath.window(
      provider: .claude,
      speed: .slow,
      usedPercent: 41,
      resetAt: resetAt,
      limitWindowSeconds: 7 * 24 * 3_600,
      now: capturedAt,
      scope: UsageScope(kind: "model", key: "sonnet-pro", displayName: "Sonnet Pro"),
      visualStyle: .menuRow
    )
    _ = cache.reconcile(
      claudeLive([fast, sonnet]),
      now: capturedAt
    )

    let cached = cache.reconcile(
      claudeFailure(),
      now: capturedAt.addingTimeInterval(600)
    )

    #expect(cached.ok)
    #expect(cached.cacheAgeSeconds == 600)
    let cachedSonnet = cached.windows.first { $0.scope?.key == "sonnet-pro" }
    #expect(cachedSonnet?.visualStyle == .menuRow)
    #expect(cachedSonnet?.usedPercent == 41)
  }

  private func makeWindow(
    provider: Provider,
    speed: WindowSpeed,
    usedPercent: Double,
    resetAt: Date,
    duration: TimeInterval,
    now: Date
  ) -> UsageWindow {
    PressureMath.window(
      provider: provider,
      speed: speed,
      usedPercent: usedPercent,
      resetAt: resetAt,
      limitWindowSeconds: duration,
      now: now
    )
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "alight-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  }
}
