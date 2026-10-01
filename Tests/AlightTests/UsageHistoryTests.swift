import Foundation
import Testing
@testable import Alight

@Suite("Live usage history")
struct UsageHistoryTests {
  @Test("cached successes and failed or deferred polls never create history")
  func cachedDataIsNotHistory() {
    var history = UsageHistory(persistenceURL: nil, now: UsageHistoryFixture.start)
    var cached = UsageHistoryFixture.result(used: 20)
    cached = ProviderResult(provider: .codex, ok: true, source: "cached", error: nil, windows: cached.windows, cacheAgeSeconds: 60)
    history.record(cached, capturedAt: UsageHistoryFixture.start)
    history.record(.failure(.codex, source: "deferred", error: "wait"), capturedAt: UsageHistoryFixture.start)
    #expect(history.observations.isEmpty)
    history.record(UsageHistoryFixture.result(used: 20), capturedAt: UsageHistoryFixture.start)
    #expect(history.observations.count == 1)
  }

  @Test("duplicate timestamps and backwards clocks preserve previous evidence")
  func clockAndDedupe() {
    var history = UsageHistory(persistenceURL: nil)
    history.record(UsageHistoryFixture.result(used: 20), capturedAt: UsageHistoryFixture.start)
    history.record(UsageHistoryFixture.result(used: 30), capturedAt: UsageHistoryFixture.start)
    history.record(UsageHistoryFixture.result(used: 40), capturedAt: UsageHistoryFixture.start.addingTimeInterval(-60))
    #expect(history.observations.count == 1)
    #expect(history.observations[0].window.usedPercent == 20)
  }

  @Test("clock recovery starts fresh coverage and preserves its fence across restart")
  func clockRecoveryStartsFreshCoverage() throws {
    let start = UsageHistoryFixture.start
    let directory = FileManager.default.temporaryDirectory.appending(path: "alight-clock-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let rollbackResults = [UsageHistoryFixture.result(used: 25),
      ProviderResult.failure(.codex, source: "error", error: "offline"),
      ProviderResult.failure(.codex, source: "deferred", error: "wait")]
    for restart in [false, true] {
      for (index, rollbackResult) in rollbackResults.enumerated() {
        let url = directory.appending(path: "\(restart)-\(index).json")
        var history = UsageHistory(persistenceURL: url, now: start)
        for (index, used) in [10.0, 15, 20].enumerated() {
          history.record(UsageHistoryFixture.result(used: used), capturedAt: start.addingTimeInterval(Double(index) * 300))
        }
        let oldSegment = history.observations.last!.segment
        history.record(rollbackResult, capturedAt: start.addingTimeInterval(300))
        #expect(history.observations.count == 3)
        if restart {
          history = UsageHistory(persistenceURL: url, now: start.addingTimeInterval(300))
          #expect(history.persistenceIssue == nil)
        }
        history.record(UsageHistoryFixture.result(used: 30), capturedAt: start.addingTimeInterval(601))
        #expect(history.observations.last!.segment != oldSegment)
        let caughtUp = UsageForecast(window: history.observations.last!.window,
          identity: UsageHistoryFixture.identity, observations: history.observations,
          now: start.addingTimeInterval(601))
        #expect(caughtUp.unavailable == .insufficientCoverage)
        #expect(caughtUp.ratePointsPerHour == nil)
        for (index, used) in [31.0, 32].enumerated() {
          history.record(UsageHistoryFixture.result(used: used), capturedAt: start.addingTimeInterval(901 + Double(index) * 300))
        }
        let rebuilt = UsageForecast(window: history.observations.last!.window,
          identity: UsageHistoryFixture.identity, observations: history.observations,
          now: start.addingTimeInterval(1201))
        #expect(rebuilt.unavailable == nil)
        #expect(rebuilt.readingCount == 3)
        #expect(rebuilt.coverageSeconds == 600)
        #expect(rebuilt.ratePointsPerHour == 12)
        #expect(history.persistenceIssue == nil)
      }
    }
  }

  @Test("unverified accounts remain isolated and cannot produce a forecast")
  func unknownIdentityDoesNotJoin() {
    var history = UsageHistory(persistenceURL: nil)
    for index in 0..<3 {
      history.record(UsageHistoryFixture.result(used: Double(20 + index), identity: nil), capturedAt: UsageHistoryFixture.start.addingTimeInterval(Double(index) * 300))
    }
    #expect(Set(history.observations.map(\.segment)).count == 3)
    let forecast = UsageForecast(window: history.observations.last!.window, identity: nil, observations: history.observations, now: UsageHistoryFixture.start.addingTimeInterval(600))
    #expect(forecast.unavailable == .accountUnknown)
  }

  @Test("account, endpoint, limit, duration, reset, gaps and decreases break continuity")
  func lineageChanges() {
    let changedIdentities = [
      UsageObservationIdentity(source: "fixture", accountPartition: "account-b", limitIdentity: "plan-a"),
      UsageObservationIdentity(source: "other-source", accountPartition: "account-a", limitIdentity: "plan-a"),
      UsageObservationIdentity(source: "fixture", accountPartition: "account-a", limitIdentity: "plan-b")
    ]
    for identity in changedIdentities {
      var history = UsageHistory(persistenceURL: nil)
      history.record(UsageHistoryFixture.result(used: 20), capturedAt: UsageHistoryFixture.start)
      history.record(UsageHistoryFixture.result(used: 21, identity: identity), capturedAt: UsageHistoryFixture.start.addingTimeInterval(300))
      #expect(history.observations[0].segment != history.observations[1].segment)
    }
    let changes = [
      UsageHistoryFixture.result(used: 10),
      UsageHistoryFixture.result(used: 21, resetAt: UsageHistoryFixture.reset.addingTimeInterval(60)),
      UsageHistoryFixture.result(used: 21, duration: 6 * 3600)
    ]
    for change in changes {
      var history = UsageHistory(persistenceURL: nil)
      history.record(UsageHistoryFixture.result(used: 20), capturedAt: UsageHistoryFixture.start)
      history.record(change, capturedAt: UsageHistoryFixture.start.addingTimeInterval(300))
      #expect(history.observations[0].segment != history.observations[1].segment)
    }
    var history = UsageHistory(persistenceURL: nil)
    history.record(UsageHistoryFixture.result(used: 20), capturedAt: UsageHistoryFixture.start)
    history.record(UsageHistoryFixture.result(used: 30), capturedAt: UsageHistoryFixture.start.addingTimeInterval(901))
    #expect(history.observations[0].segment != history.observations[1].segment)
  }

  @Test("scoped quotas never share a consumption series")
  func scopeIsolation() {
    var history = UsageHistory(persistenceURL: nil)
    history.record(UsageHistoryFixture.result(used: 20), capturedAt: UsageHistoryFixture.start)
    history.record(UsageHistoryFixture.result(used: 21, scope: .fable), capturedAt: UsageHistoryFixture.start.addingTimeInterval(300))
    #expect(history.observations[0].segment != history.observations[1].segment)
    #expect(history.points(for: history.observations[0].window).count == 1)
  }

  @Test("providers and fast/slow windows retain independent history and rates")
  func providerAndCadenceIsolation() {
    var history = UsageHistory(persistenceURL: nil)
    let start = UsageHistoryFixture.start
    for index in 0..<3 {
      let time = start.addingTimeInterval(Double(index) * 300)
      for provider in Provider.allCases {
        let windows = [WindowSpeed.fast, .slow].map { speed in
          PressureMath.window(provider: provider, speed: speed,
            usedPercent: Double(20 + index * (speed == .fast ? 2 : 1)),
            resetAt: start.addingTimeInterval(3600),
            limitWindowSeconds: speed == .fast ? 5 * 3600 : 7 * 24 * 3600,
            now: time)
        }
        history.record(ProviderResult(provider: provider, ok: true, source: "live", error: nil,
          windows: windows, observationIdentity: UsageHistoryFixture.identity), capturedAt: time)
      }
    }
    #expect(Set(history.observations.map(\.segment)).count == Provider.allCases.count * 2)
    for latest in history.observations.suffix(Provider.allCases.count * 2) {
      #expect(history.points(for: latest.window).count == 3)
      let forecast = UsageForecast(window: latest.window, identity: UsageHistoryFixture.identity,
        observations: history.observations, now: start.addingTimeInterval(600))
      #expect(forecast.unavailable == nil)
      #expect(forecast.ratePointsPerHour == (latest.window.speed == .fast ? 24 : 12))
    }
    // A malformed result cannot place another provider's window in history.
    let count = history.observations.count
    history.record(ProviderResult(provider: .claude, ok: true, source: "live", error: nil,
      windows: [UsageHistoryFixture.result(used: 90).windows[0]]), capturedAt: start.addingTimeInterval(900))
    #expect(history.observations.count == count)
  }

  @Test("derived persistence survives restart, prunes retention and reports errors")
  func persistence() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "alight-history-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "history.json")
    var history = UsageHistory(persistenceURL: url, now: UsageHistoryFixture.start)
    history.record(UsageHistoryFixture.result(used: 20), capturedAt: UsageHistoryFixture.start)
    #expect(history.persistenceIssue == nil)
    let loaded = UsageHistory(persistenceURL: url, now: UsageHistoryFixture.start.addingTimeInterval(60))
    #expect(loaded.observations.count == 1)
    let retired = UsageHistory(persistenceURL: url, now: UsageHistoryFixture.start.addingTimeInterval(UsageHistory.retention + 1))
    #expect(retired.observations.isEmpty)
    // Loading alone must retire stored bytes, without any new live sample.
    let storedAfterRetirement = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    #expect((storedAfterRetirement?["observations"] as? [Any])?.isEmpty == true)
    try Data("invalid".utf8).write(to: url)
    #expect(UsageHistory(persistenceURL: url).persistenceIssue != nil)
    // A regular file as the parent folder reliably fails without permission
    // assumptions, while keeping the successful live observation in memory.
    var unsavable = UsageHistory(persistenceURL: url.appending(path: "child.json"))
    unsavable.record(UsageHistoryFixture.result(used: 20), capturedAt: UsageHistoryFixture.start)
    #expect(unsavable.observations.count == 1)
    #expect(unsavable.persistenceIssue != nil)
  }

  @Test("failed and rejected refreshes durably enforce retention without new observations")
  func offlineRetention() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "alight-history-offline-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let later = UsageHistoryFixture.start.addingTimeInterval(UsageHistory.retention + 1)
    let inputs = [
      ProviderResult.failure(.codex, source: "error", error: "offline"),
      ProviderResult.failure(.codex, source: "deferred", error: "wait"),
      UsageHistoryFixture.result(used: 30) // old reset: rejected, no append
    ]
    for (index, input) in inputs.enumerated() {
      let url = directory.appending(path: "history-\(index).json")
      var history = UsageHistory(persistenceURL: url, now: UsageHistoryFixture.start)
      history.record(UsageHistoryFixture.result(used: 20), capturedAt: UsageHistoryFixture.start)
      history.record(input, capturedAt: later)
      #expect(history.observations.isEmpty)
      let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
      #expect((stored?["observations"] as? [Any])?.isEmpty == true)
      #expect(history.persistenceIssue == nil)
    }
  }

  @Test("offline retention retries failed persistence on the next existing poll")
  func offlineRetentionRetriesAfterWriteFailure() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "alight-retention-retry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "store")
    let heldDirectory = root.appending(path: "held")
    let url = directory.appending(path: "history.json")
    var history = UsageHistory(persistenceURL: url, now: UsageHistoryFixture.start)
    history.record(UsageHistoryFixture.result(used: 20), capturedAt: UsageHistoryFixture.start)
    try FileManager.default.moveItem(at: directory, to: heldDirectory)
    try Data("blocking file".utf8).write(to: directory)
    let later = UsageHistoryFixture.start.addingTimeInterval(UsageHistory.retention + 1)
    history.record(.failure(.codex, source: "deferred", error: "wait"), capturedAt: later)
    #expect(history.observations.isEmpty)
    #expect(history.persistenceIssue != nil)
    try FileManager.default.removeItem(at: directory)
    try FileManager.default.moveItem(at: heldDirectory, to: directory)
    // Already-pruned memory still needs to replace the stale stored document.
    history.record(.failure(.codex, source: "deferred", error: "wait"), capturedAt: later.addingTimeInterval(60))
    #expect(history.persistenceIssue == nil)
    let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    #expect((stored?["observations"] as? [Any])?.isEmpty == true)
  }

  @Test("Codex provenance is opaque, deterministic and absent for unknown accounts")
  func codexProvenance() {
    let a = CodexUsageClient.observationIdentity(accountID: "fixture-account-a", source: "fixture")
    let again = CodexUsageClient.observationIdentity(accountID: "fixture-account-a", source: "fixture")
    let b = CodexUsageClient.observationIdentity(accountID: "fixture-account-b", source: "fixture")
    #expect(a == again)
    #expect(a != b)
    #expect(a?.accountPartition.count == 64)
    #expect(a?.accountPartition.contains("fixture-account") == false)
    #expect(CodexUsageClient.observationIdentity(accountID: nil, source: "fixture") == nil)
  }

  @Test("a full history remains bounded when a new observation arrives")
  func countBound() throws {
    struct Document: Encodable { let version: Int; let observations: [UsageObservation] }
    let directory = FileManager.default.temporaryDirectory.appending(path: "alight-history-bound-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "history.json")
    let segment = UUID()
    let window = UsageHistoryFixture.result(used: 20).windows[0]
    let observations = (0..<UsageHistory.maximumCount).map { index in
      UsageObservation(id: UUID(), segment: segment, capturedAt: UsageHistoryFixture.start.addingTimeInterval(Double(index - UsageHistory.maximumCount)), window: window, identity: UsageHistoryFixture.identity)
    }
    try JSONEncoder().encode(Document(version: 1, observations: observations)).write(to: url)
    var history = UsageHistory(persistenceURL: url, now: UsageHistoryFixture.start)
    #expect(history.observations.count == UsageHistory.maximumCount)
    history.record(UsageHistoryFixture.result(used: 21), capturedAt: UsageHistoryFixture.start)
    #expect(history.observations.count == UsageHistory.maximumCount)
    #expect(history.observations.last?.window.usedPercent == 21)
    #expect(history.observations.first?.id == observations[1].id)
  }
}

enum UsageHistoryFixture {
  static let start = Date(timeIntervalSince1970: 1_800_000_000)
  static let reset = start.addingTimeInterval(3600)
  static let identity = UsageObservationIdentity(source: "fixture", accountPartition: "account-a", limitIdentity: "plan-a")

  static func result(used: Double, identity: UsageObservationIdentity? = UsageHistoryFixture.identity, resetAt: Date = UsageHistoryFixture.reset, duration: TimeInterval = 5 * 3600, scope: UsageScope? = nil) -> ProviderResult {
    let window = PressureMath.window(provider: .codex, speed: .cadence(for: duration), usedPercent: used, resetAt: resetAt, limitWindowSeconds: duration, now: start, scope: scope)
    return ProviderResult(provider: .codex, ok: true, source: "live", error: nil, windows: [window], observationIdentity: identity)
  }

  static func history(values: [Double], step: TimeInterval = 300) -> UsageHistory {
    var history = UsageHistory(persistenceURL: nil)
    for (index, used) in values.enumerated() {
      history.record(result(used: used), capturedAt: start.addingTimeInterval(Double(index) * step))
    }
    return history
  }
}
