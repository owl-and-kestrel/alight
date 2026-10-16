import Foundation
import OSLog

/// One line of the outbox: an exported `ok.alight.quota-snapshot.v1`, exactly
/// what Fieldbook reads, plus Alight's per-provider continuity identity.
struct QuotaOutboxEntry: Equatable, Sendable {
  static let schema = "ok.alight.quota-outbox-entry.v1"

  /// Monotonic across files and restarts; Fieldbook ingests in this order.
  var sequence: Int
  /// Alight's continuity identity (source and account partition digests)
  /// for the providers that had one this refresh.
  var identities: [Provider: UsageObservationIdentity]
  /// The snapshot, compact JSON.
  var snapshot: Data

  var writtenAt: Date? {
    (try? JSONSerialization.jsonObject(with: snapshot) as? [String: Any])?["writtenAt"]
      .flatMap { $0 as? String }
      .flatMap(FieldbookTime.date)
  }
}

/// Append-only outbox of the quota snapshots Alight exports for Fieldbook,
/// and the only persisted history Alight keeps: everything it shows over
/// time is Fieldbook's reading of these snapshots.
///
/// One JSON line per entry, in a file per UTC day
/// (`quota-snapshots-YYYY-MM-DD.jsonl`), mode 0600, 14 days retained (checked
/// at load and whenever a new day's file starts). The last sequence is also
/// kept in a `sequence` file, so numbering continues after every day file has
/// expired. A
/// snapshot is appended when any provider's reading changed or a heartbeat is
/// due, so unchanged refreshes do not grow the log but continuity
/// (`UsageForecast.maximumGap`) is never broken.
struct QuotaOutbox: Sendable {
  static let retention: TimeInterval = UsageHistory.retention
  static let heartbeat: TimeInterval = 10 * 60
  private static let logger = Logger(subsystem: "com.owlandkestrel.alight", category: "outbox")

  let directory: URL
  private(set) var lastSequence = 0
  private var lastSignature: Data?
  private var lastWrittenAt: Date?
  private var lastWrittenDay: String?
  private(set) var issue: String?

  init(directory: URL) {
    self.directory = directory
  }

  static var standardDirectory: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appending(path: "Alight", directoryHint: .isDirectory)
      .appending(path: "fieldbook-outbox", directoryHint: .isDirectory)
  }

  enum AppendOutcome: Equatable {
    case appended(QuotaOutboxEntry)
    /// Every provider reads as in the last entry, inside the heartbeat.
    case unchanged
    case failed
  }

  /// Every retained entry in sequence order. Deletes day files past
  /// retention and skips lines that do not decode (a write cut short).
  mutating func load(now: Date) -> [QuotaOutboxEntry] {
    removeExpiredFiles(now: now)
    var entries: [QuotaOutboxEntry] = []
    var skipped = 0
    for file in dayFiles() {
      guard let data = try? Data(contentsOf: file) else { continue }
      for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
        if let entry = Self.decode(Data(line)) { entries.append(entry) } else { skipped += 1 }
      }
    }
    if skipped > 0 { Self.logger.error("Skipped \(skipped, privacy: .public) unreadable outbox lines") }
    entries.sort { $0.sequence < $1.sequence }
    lastSequence = max(lastSequence, entries.last?.sequence ?? 0, storedSequence() ?? 0)
    if let last = entries.last {
      lastSignature = Self.signature(last.snapshot)
      lastWrittenAt = last.writtenAt
    }
    return entries
  }

  /// Appends `snapshot` (encoded, any formatting) unless every provider reads
  /// as in the last entry and the heartbeat is not yet due.
  @discardableResult
  mutating func append(_ snapshot: Data, identities: [Provider: UsageObservationIdentity]) -> AppendOutcome {
    guard let object = try? JSONSerialization.jsonObject(with: snapshot),
      let compact = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
      let writtenAt = (object as? [String: Any])?["writtenAt"].flatMap({ $0 as? String }).flatMap(FieldbookTime.date)
    else { return .failed }
    let signature = Self.signature(compact)
    if signature != nil, signature == lastSignature, let lastWrittenAt,
      writtenAt >= lastWrittenAt, writtenAt.timeIntervalSince(lastWrittenAt) < Self.heartbeat {
      return .unchanged
    }
    let entry = QuotaOutboxEntry(sequence: lastSequence + 1, identities: identities, snapshot: compact)
    let day = Self.dayName(writtenAt)
    do {
      try write(entry, day: day)
      // The sequence file only speeds continuity across full expiry; the day
      // files stay the record, so a failure here is not an append failure.
      try? storeSequence(entry.sequence)
      if day != lastWrittenDay {
        // A long-running app crosses days without reloading.
        removeExpiredFiles(now: writtenAt)
        lastWrittenDay = day
      }
      lastSequence = entry.sequence
      lastSignature = signature
      lastWrittenAt = writtenAt
      issue = nil
      return .appended(entry)
    } catch {
      issue = "Usage history could not be saved. Live gauges still work; check Application Support/Alight permissions."
      Self.logger.error("Outbox append failed: \(String(describing: error), privacy: .public)")
      return .failed
    }
  }

  // MARK: Lines

  static func encode(_ entry: QuotaOutboxEntry) throws -> Data {
    let identities = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(Dictionary(uniqueKeysWithValues: entry.identities.map { ($0.key.rawValue, $0.value) }))
    )
    let line: [String: Any] = [
      "schema": QuotaOutboxEntry.schema,
      "sequence": entry.sequence,
      "identities": identities,
      "snapshot": try JSONSerialization.jsonObject(with: entry.snapshot),
    ]
    return try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])
  }

  static func decode(_ line: Data) -> QuotaOutboxEntry? {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      object["schema"] as? String == QuotaOutboxEntry.schema,
      let sequence = object["sequence"] as? Int,
      let snapshotObject = object["snapshot"],
      let snapshot = try? JSONSerialization.data(withJSONObject: snapshotObject, options: [.sortedKeys, .withoutEscapingSlashes]),
      let identitiesData = try? JSONSerialization.data(withJSONObject: object["identities"] ?? [String: Any]()),
      let raw = try? JSONDecoder().decode([String: UsageObservationIdentity].self, from: identitiesData)
    else { return nil }
    var identities: [Provider: UsageObservationIdentity] = [:]
    for (key, identity) in raw { if let provider = Provider(rawValue: key) { identities[provider] = identity } }
    return QuotaOutboxEntry(sequence: sequence, identities: identities, snapshot: snapshot)
  }

  /// What a reading is, without when it was taken: each provider's entry
  /// minus its timestamps and cache age, and minus the reset of any window
  /// with nothing used (a window that has not started reports a reset that
  /// moves with the clock, as Antigravity's do).
  static func signature(_ snapshot: Data) -> Data? {
    guard let object = try? JSONSerialization.jsonObject(with: snapshot) as? [String: Any],
      let providers = object["providers"] as? [[String: Any]]
    else { return nil }
    let stripped = providers.map { provider -> [String: Any] in
      var entry = provider.filter { !["attemptedAt", "capturedAt", "cacheAgeSeconds"].contains($0.key) }
      if let groups = entry["groups"] as? [[String: Any]] {
        entry["groups"] = groups.map { group -> [String: Any] in
          var group = group
          if let windows = group["windows"] as? [[String: Any]] {
            group["windows"] = windows.map { window in
              (window["usedPercentRaw"] as? Double) == 0 ? window.filter { $0.key != "resetAt" } : window
            }
          }
          return group
        }
      }
      return entry
    }
    return try? JSONSerialization.data(withJSONObject: stripped, options: [.sortedKeys])
  }

  // MARK: Files

  private func write(_ entry: QuotaOutboxEntry, day: String) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appending(path: "quota-snapshots-\(day).jsonl")
    if !fileManager.fileExists(atPath: url.path) {
      guard fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw CocoaError(.fileWriteUnknown)
      }
    }
    try Self.restrictToOwner(url)
    var line = try Self.encode(entry)
    line.append(UInt8(ascii: "\n"))
    let handle = try FileHandle(forUpdating: url)
    defer { try? handle.close() }
    // A write cut short leaves a line without its newline; end it first so
    // this entry is not glued onto the fragment (and lost with it).
    let end = try handle.seekToEnd()
    if end > 0 {
      try handle.seek(toOffset: end - 1)
      if try handle.read(upToCount: 1) != Data([UInt8(ascii: "\n")]) {
        line.insert(UInt8(ascii: "\n"), at: 0)
      }
      try handle.seekToEnd()
    }
    try handle.write(contentsOf: line)
  }

  /// Files written before (or changed since) keep 0600.
  private static func restrictToOwner(_ url: URL) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    if (attributes[.posixPermissions] as? NSNumber)?.intValue != 0o600 {
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
  }

  /// Deletes this outbox's own day files older than retention, nothing else.
  private func removeExpiredFiles(now: Date) {
    let cutoff = Self.dayName(now.addingTimeInterval(-Self.retention))
    for file in dayFiles() where Self.day(of: file) < cutoff {
      try? FileManager.default.removeItem(at: file)
    }
  }

  private var sequenceURL: URL { directory.appending(path: "sequence") }

  private func storedSequence() -> Int? {
    (try? String(contentsOf: sequenceURL, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
  }

  private func storeSequence(_ sequence: Int) throws {
    try Data("\(sequence)\n".utf8).write(to: sequenceURL, options: .atomic)
    try Self.restrictToOwner(sequenceURL)
  }

  /// Only `quota-snapshots-YYYY-MM-DD.jsonl`: retention never touches
  /// anything else in the directory.
  private func dayFiles() -> [URL] {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return files.filter { file in
      file.pathExtension == "jsonl" && file.lastPathComponent.hasPrefix("quota-snapshots-")
        && Self.day(of: file).wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil
    }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private static func day(of file: URL) -> String {
    String(file.deletingPathExtension().lastPathComponent.dropFirst("quota-snapshots-".count))
  }

  static func dayName(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }
}
