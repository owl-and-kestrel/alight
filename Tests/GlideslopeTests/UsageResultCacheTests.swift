import Foundation
import Testing
@testable import Glideslope

@Suite("Usage result cache")
struct UsageResultCacheTests {
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
    let live = ProviderResult(
      provider: .claude,
      ok: true,
      source: "live",
      error: nil,
      windows: [liveWindow]
    )
    #expect(firstProcess.reconcile(live, now: capturedAt).source == "live")

    var relaunchedProcess = UsageResultCache(persistenceURL: cacheURL)
    let checkedAt = capturedAt.addingTimeInterval(600)
    let authFailure = ProviderResult.failure(
      .claude,
      source: "expired",
      error: "token expired",
      needsAuth: true
    )
    let cached = relaunchedProcess.reconcile(authFailure, now: checkedAt)

    #expect(cached.ok)
    #expect(cached.source == "cached")
    #expect(cached.error == "token expired")
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
      ProviderResult(
        provider: .claude,
        ok: true,
        source: "live",
        error: nil,
        windows: [fast, weekly]
      ),
      now: capturedAt
    )

    let cached = cache.reconcile(
      .failure(.claude, source: "error", error: "usage fetch failed"),
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
      ProviderResult(
        provider: .claude,
        ok: true,
        source: "live",
        error: nil,
        windows: [fast]
      ),
      now: capturedAt
    )

    let failure = cache.reconcile(
      .failure(.claude, source: "expired", error: "token expired", needsAuth: true),
      now: capturedAt.addingTimeInterval(120)
    )
    #expect(!failure.ok)
    #expect(failure.needsAuth)
    #expect(failure.windows.isEmpty)
    #expect(failure.error?.contains("last live 2m ago") == true)

    let afterPurge = cache.reconcile(
      .failure(.claude, source: "error", error: "still unavailable"),
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
      ProviderResult(
        provider: .claude,
        ok: true,
        source: "live",
        error: nil,
        windows: [fast, weekly, fable]
      ),
      now: capturedAt
    )

    let authoritative = cache.reconcile(
      ProviderResult(
        provider: .claude,
        ok: true,
        source: "live",
        error: nil,
        windows: [fast, weekly]
      ),
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
      ProviderResult(
        provider: .claude,
        ok: true,
        source: "live",
        error: nil,
        windows: [fast, sonnet]
      ),
      now: capturedAt
    )

    let cached = cache.reconcile(
      .failure(.claude, source: "error", error: "usage fetch failed"),
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
      .appending(path: "glideslope-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  }
}
