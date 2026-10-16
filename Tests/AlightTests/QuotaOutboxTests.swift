import Foundation
import Testing
@testable import Alight

@Suite("Fieldbook outbox")
@MainActor
struct QuotaOutboxTests {
  private let start = FieldbookQuotaTests.now
  private let identity = UsageObservationIdentity(source: "test", accountPartition: "acct", limitIdentity: nil)

  private func directory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "alight-outbox-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func snapshot(used: Double, at date: Date, sequence: Int = 0) throws -> Data {
    try FieldbookQuotaTests.snapshot([try FieldbookQuotaTests.codexResult(used: used, at: date)], at: date, sequence: sequence)
  }

  @Test("changes append, repeats wait for the heartbeat, and sequence survives a reload")
  func appendAndThin() throws {
    let dir = directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var outbox = QuotaOutbox(directory: dir)

    guard case .appended(let first) = outbox.append(try snapshot(used: 10, at: start), identities: [.codex: identity]) else {
      Issue.record("first snapshot not appended"); return
    }
    #expect(first.sequence == 1)
    #expect(outbox.append(try snapshot(used: 10, at: start.addingTimeInterval(60), sequence: 1), identities: [.codex: identity]) == .unchanged)
    if case .appended = outbox.append(try snapshot(used: 11, at: start.addingTimeInterval(120), sequence: 2), identities: [.codex: identity]) {} else {
      Issue.record("change not appended")
    }
    if case .appended = outbox.append(try snapshot(used: 11, at: start.addingTimeInterval(120 + QuotaOutbox.heartbeat), sequence: 3), identities: [.codex: identity]) {} else {
      Issue.record("heartbeat not appended")
    }

    var reloaded = QuotaOutbox(directory: dir)
    let entries = reloaded.load(now: start.addingTimeInterval(3600))
    #expect(entries.map(\.sequence) == [1, 2, 3])
    #expect(entries.first?.identities == [.codex: identity])
    #expect(reloaded.append(try snapshot(used: 11, at: start.addingTimeInterval(121 + QuotaOutbox.heartbeat), sequence: 4), identities: [:]) == .unchanged)
    guard case .appended(let next) = reloaded.append(try snapshot(used: 12, at: start.addingTimeInterval(2000), sequence: 5), identities: [:]) else {
      Issue.record("post-reload change not appended"); return
    }
    #expect(next.sequence == 4)
  }

  @Test("lines hold the snapshot exactly as Fieldbook reads it")
  func lineFormat() throws {
    let data = try snapshot(used: 10, at: start)
    let entry = QuotaOutboxEntry(sequence: 7, identities: [.codex: identity], snapshot: data)
    let line = try QuotaOutbox.encode(entry)
    #expect(!line.contains(UInt8(ascii: "\n")))
    let decoded = try #require(QuotaOutbox.decode(line))
    #expect(decoded.sequence == 7)
    #expect(decoded.identities == [.codex: identity])
    let original = try JSONSerialization.jsonObject(with: data) as? NSDictionary
    let roundTripped = try JSONSerialization.jsonObject(with: decoded.snapshot) as? NSDictionary
    #expect(original == roundTripped)
    #expect(QuotaProjection.reading(of: decoded)?.usage(for: .codex) != nil)
  }

  @Test("files are per UTC day, private, and expire after retention; broken lines are skipped")
  func filesAndRetention() throws {
    let dir = directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var outbox = QuotaOutbox(directory: dir)
    let old = start.addingTimeInterval(-QuotaOutbox.retention - 2 * 86400)
    outbox.append(try snapshot(used: 5, at: old), identities: [:])
    outbox.append(try snapshot(used: 6, at: start, sequence: 1), identities: [:])

    let todayFile = dir.appending(path: "quota-snapshots-\(QuotaOutbox.dayName(start)).jsonl")
    let attributes = try FileManager.default.attributesOfItem(atPath: todayFile.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let handle = try FileHandle(forWritingTo: todayFile)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"schema\":\"ok.alight.quota-outbox-entry.v1\",\"sequ".utf8))
    try handle.close()

    var reloaded = QuotaOutbox(directory: dir)
    #expect(reloaded.load(now: start).map(\.sequence) == [2])
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [todayFile.lastPathComponent])
  }

  @Test("history is Fieldbook's reading of the outbox, with continuity and forecasts")
  func projection() throws {
    let dir = directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var outbox = QuotaOutbox(directory: dir)
    for minute in 0..<30 {
      outbox.append(try snapshot(used: Double(minute / 3), at: start.addingTimeInterval(Double(minute) * 60), sequence: minute),
        identities: [.codex: identity])
    }
    var reloaded = QuotaOutbox(directory: dir)
    let entries = reloaded.load(now: start.addingTimeInterval(1800))
    #expect(entries.count == 10)
    let history = QuotaProjection.history(base: UsageHistory(persistenceURL: nil, now: start), entries: entries)
    #expect(history.observations.count == 10)
    #expect(Set(history.observations.map(\.segment)).count == 1)
    #expect(history.observations.map(\.window.usedPercent) == (0..<10).map(Double.init))

    let current = try #require(history.observations.last?.window)
    let forecast = UsageForecast(window: current, identity: identity, observations: history.observations, now: start.addingTimeInterval(29 * 60))
    #expect(forecast.unavailable == nil)
    #expect(forecast.ratePointsPerHour != nil)
  }

  @Test("the pre-Fieldbook history stays visible beneath the outbox")
  func legacyBase() throws {
    let dir = directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let legacyURL = dir.appending(path: "usage-history.json")
    var saved = UsageHistory(persistenceURL: legacyURL, now: start)
    for minute in 0..<5 {
      let at = start.addingTimeInterval(Double(minute - 10) * 60)
      saved.record(try FieldbookQuotaTests.codexResult(used: 1, at: at).replacingWindows(
        try FieldbookQuotaTests.codexResult(used: 1, at: at).windows
      ).withIdentity(identity), capturedAt: at)
    }
    #expect(saved.observations.count == 5)

    let base = UsageHistory.legacy(at: legacyURL, now: start)
    #expect(base.observations.count == 5)
    #expect(FileManager.default.fileExists(atPath: legacyURL.path))

    var outbox = QuotaOutbox(directory: dir.appending(path: "outbox"))
    let entry = outbox.append(try snapshot(used: 2, at: start), identities: [.codex: identity])
    guard case .appended(let appended) = entry else { Issue.record("not appended"); return }
    let history = QuotaProjection.history(base: base, entries: [appended])
    #expect(history.observations.count == 6)
    #expect(history.observations.last?.window.usedPercent == 2)
  }
}

private extension ProviderResult {
  func withIdentity(_ identity: UsageObservationIdentity) -> ProviderResult {
    var copy = self
    copy.observationIdentity = identity
    return copy
  }
}
