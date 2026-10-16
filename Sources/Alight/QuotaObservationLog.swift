import Foundation
import OSLog

/// One line of the outbox: a Fieldbook quota observation plus the local facts
/// Fieldbook ingestion and Alight's projections need alongside it.
struct QuotaOutboxEntry: Codable, Equatable, Sendable {
  static let schema = "ok.alight.quota-outbox-entry.v1"

  var schema: String = Self.schema
  /// Monotonic across files and restarts; Fieldbook ingests in this order.
  var sequence: Int
  var provider: Provider
  /// Fieldbook `usageAccountRef` digest, when the account was identified.
  var accountRef: String?
  /// Alight's continuity identity (source and account partition digests).
  var identity: UsageObservationIdentity?
  var observation: QuotaObservation
}

/// Append-only outbox of `ok.fieldbook.quota-observation.v1` records: the
/// data that goes into Fieldbook, and the only persisted history Alight
/// keeps. Everything Alight shows over time is projected from it.
///
/// One JSON line per entry, in a file per UTC day
/// (`quota-observations-YYYY-MM-DD.jsonl`), mode 0600. A reading is appended
/// when any window changed or a heartbeat is due, so unchanged polls do not
/// grow the log but continuity (`UsageForecast.maximumGap`) is never broken.
struct QuotaObservationLog: Sendable {
  static let retention: TimeInterval = UsageHistory.retention
  static let heartbeat: TimeInterval = 10 * 60
  private static let logger = Logger(subsystem: "com.owlandkestrel.alight", category: "outbox")

  let directory: URL
  private(set) var lastSequence = 0
  private var lastAppended: [Provider: QuotaOutboxEntry] = [:]
  private(set) var issue: String?

  init(directory: URL) {
    self.directory = directory
  }

  static var standardDirectory: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appending(path: "Alight", directoryHint: .isDirectory)
      .appending(path: "fieldbook-outbox", directoryHint: .isDirectory)
  }

  var isEmpty: Bool { dayFiles().isEmpty }

  /// Every retained entry in sequence order. Deletes day files past
  /// retention and skips lines that do not decode (a write cut short).
  mutating func load(now: Date) -> [QuotaOutboxEntry] {
    let cutoff = Self.dayName(now.addingTimeInterval(-Self.retention))
    var entries: [QuotaOutboxEntry] = []
    var skipped = 0
    let decoder = JSONDecoder()
    for file in dayFiles() {
      if Self.day(of: file) < cutoff {
        try? FileManager.default.removeItem(at: file)
        continue
      }
      guard let data = try? Data(contentsOf: file) else { continue }
      for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
        if let entry = try? decoder.decode(QuotaOutboxEntry.self, from: line), entry.schema == QuotaOutboxEntry.schema {
          entries.append(entry)
        } else {
          skipped += 1
        }
      }
    }
    if skipped > 0 { Self.logger.error("Skipped \(skipped, privacy: .public) unreadable outbox lines") }
    entries.sort { $0.sequence < $1.sequence }
    lastSequence = max(lastSequence, entries.last?.sequence ?? 0)
    for entry in entries { lastAppended[entry.provider] = entry }
    return entries
  }

  enum AppendOutcome: Equatable {
    case appended(QuotaOutboxEntry)
    /// Same windows as this provider's last entry, inside the heartbeat.
    case unchanged
    case failed
  }

  /// Appends unless nothing changed since this provider's last entry and the
  /// heartbeat is not yet due.
  @discardableResult
  mutating func append(
    _ observation: QuotaObservation,
    provider: Provider,
    identity: UsageObservationIdentity?,
    accountRef: String?
  ) -> AppendOutcome {
    guard let observedAt = observation.observedAt.flatMap(QuotaObservation.date) else { return .failed }
    if let previous = lastAppended[provider],
      previous.identity == identity,
      Self.sameWindows(previous.observation, observation),
      let previousAt = previous.observation.observedAt.flatMap(QuotaObservation.date),
      observedAt >= previousAt,
      observedAt.timeIntervalSince(previousAt) < Self.heartbeat {
      return .unchanged
    }
    let entry = QuotaOutboxEntry(
      sequence: lastSequence + 1, provider: provider, accountRef: accountRef, identity: identity, observation: observation
    )
    do {
      try write(entry, day: Self.dayName(observedAt))
      lastSequence = entry.sequence
      lastAppended[provider] = entry
      issue = nil
      return .appended(entry)
    } catch {
      issue = "Usage history could not be saved. Live gauges still work; check Application Support/Alight permissions."
      Self.logger.error("Outbox append failed: \(String(describing: error), privacy: .public)")
      return .failed
    }
  }

  /// One-time import of the pre-Fieldbook history file: each capture becomes
  /// an observation per provider, thinned like live appends.
  mutating func importLegacy(_ history: UsageHistory) -> Int {
    var imported = 0
    let groups = Dictionary(grouping: history.observations) { "\($0.window.provider.rawValue)@\($0.capturedAt.timeIntervalSince1970)" }
    let ordered = groups.values.compactMap { group in group.first.map { ($0.capturedAt, $0.window.provider, group) } }
      .sorted { ($0.0, $0.1.rawValue) < ($1.0, $1.1.rawValue) }
    for (capturedAt, provider, group) in ordered {
      let result = ProviderResult(
        provider: provider, ok: true, source: "live", error: nil, windows: group.map(\.window),
        observationIdentity: group.first?.identity
      )
      guard let observation = AlightQuotaProducer.observation(for: result, capturedAt: capturedAt) else { continue }
      if case .appended = append(observation, provider: provider, identity: group.first?.identity, accountRef: nil) {
        imported += 1
      }
    }
    return imported
  }

  // MARK: Files

  private func write(_ entry: QuotaOutboxEntry, day: String) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appending(path: "quota-observations-\(day).jsonl")
    if !fileManager.fileExists(atPath: url.path) {
      guard fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw CocoaError(.fileWriteUnknown)
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var line = try encoder.encode(entry)
    line.append(UInt8(ascii: "\n"))
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
  }

  private func dayFiles() -> [URL] {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.lastPathComponent.hasPrefix("quota-observations-") && $0.pathExtension == "jsonl" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private static func day(of file: URL) -> String {
    String(file.deletingPathExtension().lastPathComponent.dropFirst("quota-observations-".count))
  }

  static func dayName(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  private static func sameWindows(_ lhs: QuotaObservation, _ rhs: QuotaObservation) -> Bool {
    func key(_ observation: QuotaObservation) -> [String] {
      observation.windows.map { "\($0.windowId)|\($0.usedFraction)|\($0.resetsAt)|\($0.windowSeconds)" }.sorted()
    }
    return key(lhs) == key(rhs)
  }
}
