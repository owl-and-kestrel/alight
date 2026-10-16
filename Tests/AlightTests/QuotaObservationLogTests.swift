import Foundation
import Testing
@testable import Alight

@Suite("Fieldbook outbox log")
struct QuotaObservationLogTests {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)
  private let identity = UsageObservationIdentity(source: "test", accountPartition: "acct", limitIdentity: nil)

  private func directory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "alight-outbox-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func observation(_ provider: Provider = .codex, used: Double, at date: Date, resetIn: TimeInterval = 86400) -> QuotaObservation {
    let window = PressureMath.window(
      provider: provider, speed: .slow, usedPercent: used, resetAt: start.addingTimeInterval(resetIn),
      limitWindowSeconds: 7 * 86400, now: date
    )
    return AlightQuotaProducer.observation(
      for: ProviderResult(provider: provider, ok: true, source: "live", error: nil, windows: [window]), capturedAt: date
    )!
  }

  @Test("changes append, repeats wait for the heartbeat, and sequence survives a reload")
  func appendAndThin() throws {
    let dir = directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var log = QuotaObservationLog(directory: dir)
    #expect(log.isEmpty)

    guard case .appended(let first) = log.append(observation(used: 10, at: start), provider: .codex, identity: identity, accountRef: "ref") else {
      Issue.record("first reading not appended"); return
    }
    #expect(first.sequence == 1)
    #expect(log.append(observation(used: 10, at: start.addingTimeInterval(60)), provider: .codex, identity: identity, accountRef: "ref") == .unchanged)
    // Another provider is independent.
    if case .appended = log.append(observation(.antigravity, used: 10, at: start.addingTimeInterval(61)), provider: .antigravity, identity: identity, accountRef: nil) {} else {
      Issue.record("other provider not appended")
    }
    // A change appends at once; an identity change does too.
    if case .appended = log.append(observation(used: 11, at: start.addingTimeInterval(120)), provider: .codex, identity: identity, accountRef: "ref") {} else {
      Issue.record("change not appended")
    }
    let other = UsageObservationIdentity(source: "test", accountPartition: "other", limitIdentity: nil)
    if case .appended = log.append(observation(used: 11, at: start.addingTimeInterval(180)), provider: .codex, identity: other, accountRef: "ref") {} else {
      Issue.record("identity change not appended")
    }
    // The heartbeat appends an unchanged reading.
    if case .appended = log.append(observation(used: 11, at: start.addingTimeInterval(180 + QuotaObservationLog.heartbeat)), provider: .codex, identity: other, accountRef: "ref") {} else {
      Issue.record("heartbeat not appended")
    }

    var reloaded = QuotaObservationLog(directory: dir)
    let entries = reloaded.load(now: start.addingTimeInterval(3600))
    #expect(entries.map(\.sequence) == [1, 2, 3, 4, 5])
    #expect(entries.first?.accountRef == "ref")
    #expect(entries.first?.observation == observation(used: 10, at: start))
    #expect(reloaded.append(observation(used: 11, at: start.addingTimeInterval(181 + QuotaObservationLog.heartbeat)), provider: .codex, identity: other, accountRef: "ref") == .unchanged)
    guard case .appended(let next) = reloaded.append(observation(used: 12, at: start.addingTimeInterval(2000)), provider: .codex, identity: other, accountRef: "ref") else {
      Issue.record("post-reload change not appended"); return
    }
    #expect(next.sequence == 6)
  }

  @Test("files are per UTC day, private, and expire after retention; broken lines are skipped")
  func filesAndRetention() throws {
    let dir = directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var log = QuotaObservationLog(directory: dir)
    let old = start.addingTimeInterval(-QuotaObservationLog.retention - 2 * 86400)
    log.append(observation(used: 5, at: old, resetIn: -QuotaObservationLog.retention), provider: .codex, identity: identity, accountRef: nil)
    log.append(observation(used: 6, at: start), provider: .codex, identity: identity, accountRef: nil)

    let todayFile = dir.appending(path: "quota-observations-\(QuotaObservationLog.dayName(start)).jsonl")
    let attributes = try FileManager.default.attributesOfItem(atPath: todayFile.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let handle = try FileHandle(forWritingTo: todayFile)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"schema\":\"ok.alight.quota-outbox-entry.v1\",\"sequ".utf8))
    try handle.close()

    var reloaded = QuotaObservationLog(directory: dir)
    let entries = reloaded.load(now: start)
    #expect(entries.map(\.sequence) == [2])
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(files == [todayFile.lastPathComponent])
  }

  @Test("history projected from the log is what live recording would have built")
  func projection() throws {
    let dir = directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var log = QuotaObservationLog(directory: dir)
    for minute in 0..<30 {
      log.append(observation(used: Double(minute / 3), at: start.addingTimeInterval(Double(minute) * 60)), provider: .codex, identity: identity, accountRef: nil)
    }
    var reloaded = QuotaObservationLog(directory: dir)
    let entries = reloaded.load(now: start.addingTimeInterval(1800))
    #expect(entries.count == 10)
    let history = QuotaProjection.history(from: entries, now: start.addingTimeInterval(1800))
    #expect(history.observations.count == 10)
    #expect(Set(history.observations.map(\.segment)).count == 1)
    // A percentage passes through a fraction of 100, so compare within float error.
    #expect(zip(history.observations.map(\.window.usedPercent), 0..<10).allSatisfy { abs($0 - Double($1)) < 1e-9 })

    // A forecast over the projection works as it did over the old history.
    let current = try #require(history.observations.last?.window)
    let forecast = UsageForecast(window: current, identity: identity, observations: history.observations, now: start.addingTimeInterval(29 * 60))
    #expect(forecast.unavailable == nil)
    #expect(forecast.ratePointsPerHour != nil)
  }

  @Test("the pre-Fieldbook history imports once, thinned")
  func legacyImport() throws {
    let dir = directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var legacy = UsageHistory(persistenceURL: nil, now: start)
    for minute in 0..<20 {
      let at = start.addingTimeInterval(Double(minute) * 60)
      let window = PressureMath.window(provider: .claude, speed: .fast, usedPercent: minute < 10 ? 20 : 30,
        resetAt: start.addingTimeInterval(4 * 3600), limitWindowSeconds: 18000, now: at)
      legacy.record(ProviderResult(provider: .claude, ok: true, source: "live", error: nil, windows: [window], observationIdentity: identity), capturedAt: at)
    }
    #expect(legacy.observations.count == 20)
    var log = QuotaObservationLog(directory: dir)
    #expect(log.importLegacy(legacy) == 2)
    var reloaded = QuotaObservationLog(directory: dir)
    let entries = reloaded.load(now: start.addingTimeInterval(1200))
    #expect(entries.map(\.provider) == [.claude, .claude])
    #expect(entries.map(\.identity) == [identity, identity])
    #expect(entries.map { $0.observation.windows[0].usedFraction } == [0.2, 0.3])
  }
}
