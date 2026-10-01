import Foundation

/// Public, derived provenance only. Never put tokens, raw account IDs, or a
/// credential path in these fields. A missing quota denominator/version remains
/// unknown; percentages cannot reveal an unreported plan change.
struct UsageObservationIdentity: Codable, Equatable, Sendable {
  let source: String
  let accountPartition: String
  let limitIdentity: String?
}

struct UsageObservation: Codable, Identifiable, Sendable {
  let id: UUID
  let segment: UUID
  let capturedAt: Date
  let window: UsageWindow
  let identity: UsageObservationIdentity?
}

/// Bounded derived history, fed exclusively by the existing refresh task before
/// cache reconciliation. It owns no polling, credentials, or provider runtime.
struct UsageHistory: Sendable {
  static let retention: TimeInterval = 14 * 24 * 60 * 60
  static let maximumCount = 20_000
  private(set) var observations: [UsageObservation] = []
  private(set) var persistenceIssue: String?
  private let persistenceURL: URL?
  /// A wall-clock regression invalidates elapsed-time continuity even after
  /// the clock catches up. Persist this fence until the next valid reading.
  private var clockDiscontinuities: Set<String> = []
  private var persistencePending = false

  init(persistenceURL: URL? = UsageHistory.defaultPersistenceURL, now: Date = Date()) {
    self.persistenceURL = persistenceURL
    guard let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: persistenceURL.path)
      guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 16_000_000 else {
        throw HistoryError.invalidDocument
      }
      let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: persistenceURL))
      guard document.version == 1, document.observations.count <= Self.maximumCount,
        document.observations.allSatisfy(Self.valid) else { throw HistoryError.invalidDocument }
      let discontinuities = Set(document.clockDiscontinuities ?? [])
      guard discontinuities.count <= Self.maximumCount,
        discontinuities.isSubset(of: Set(document.observations.map { $0.window.id })) else {
        throw HistoryError.invalidDocument
      }
      clockDiscontinuities = discontinuities
      observations = document.observations.sorted { $0.capturedAt < $1.capturedAt }
      if prune(now: now) { persist() }
    } catch {
      persistenceIssue = "History could not be loaded. Live gauges still work; new observations will start a new history."
    }
  }

  /// Completion time comes from the live request, not UsageStatus.generatedAt
  /// or a cached refresh. Repeated timestamps and clock reversal are rejected.
  mutating func record(_ result: ProviderResult, capturedAt: Date) {
    guard capturedAt.timeIntervalSince1970.isFinite else { return }
    let pruned = prune(now: capturedAt)
    let fencesBefore = clockDiscontinuities
    // A failed/deferred poll also reveals clock movement. Do not let a later
    // successful poll silently bridge it, including after an app restart.
    clockDiscontinuities.formUnion(observations.lazy.filter { $0.capturedAt > capturedAt }.map { $0.window.id })
    let clockChanged = fencesBefore != clockDiscontinuities
    guard result.ok, result.source == "live", result.cacheAgeSeconds == nil else {
      // Retention is a durable bound even while offline or between live polls.
      if pruned || clockChanged || persistencePending { persist() }
      return
    }
    var appended = false
    for window in result.windows {
      guard window.provider == result.provider, window.resetAt > capturedAt,
        window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
        window.limitWindowSeconds.isFinite, window.limitWindowSeconds > 0 else { continue }
      let previous = observations.last { $0.window.id == window.id }
      if let previous, capturedAt <= previous.capturedAt { continue }
      let identity = result.observationIdentity.flatMap {
        $0.source.isEmpty || $0.accountPartition.isEmpty ? nil : $0
      }
      // Unverified accounts get isolated points. Reset, source, account,
      // duration, reported limit changes, decreases, and long gaps break lines.
      let continuous = previous.map {
        !clockDiscontinuities.contains(window.id) && identity != nil && $0.identity == identity &&
          $0.window.resetAt == window.resetAt &&
          $0.window.limitWindowSeconds == window.limitWindowSeconds &&
          window.usedPercent >= $0.window.usedPercent &&
          capturedAt.timeIntervalSince($0.capturedAt) <= UsageForecast.maximumGap
      } ?? false
      observations.append(UsageObservation(id: UUID(), segment: continuous ? previous!.segment : UUID(), capturedAt: capturedAt, window: window, identity: identity))
      clockDiscontinuities.remove(window.id)
      appended = true
    }
    let prunedAfterAppend = prune(now: capturedAt)
    if appended || pruned || prunedAfterAppend || clockChanged || persistencePending { persist() }
  }

  func points(for window: UsageWindow) -> [UsageObservation] {
    observations.filter { $0.window.id == window.id }
  }

  @discardableResult
  private mutating func prune(now: Date) -> Bool {
    let countBefore = observations.count
    let fencesBefore = clockDiscontinuities
    // Keep future points after a wall-clock reversal, so forecasting can refuse
    // explicitly instead of silently erasing the evidence of clock movement.
    observations.removeAll { $0.capturedAt < now.addingTimeInterval(-Self.retention) }
    if observations.count > Self.maximumCount { observations.removeFirst(observations.count - Self.maximumCount) }
    clockDiscontinuities.formIntersection(Set(observations.map { $0.window.id }))
    return observations.count != countBefore || clockDiscontinuities != fencesBefore
  }

  private mutating func persist() {
    guard let persistenceURL else { return }
    // Retry at the next existing finite-clock record attempt. A failed write
    // must not leave retention/clock fences permanently dirty during offline
    // polling, and this adds no timer or independent I/O loop.
    persistencePending = true
    do {
      let folder = persistenceURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let data = try JSONEncoder().encode(Document(version: 1, observations: observations,
        clockDiscontinuities: clockDiscontinuities.sorted()))
      try data.write(to: persistenceURL, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: persistenceURL.path)
      persistenceIssue = nil
      persistencePending = false
    } catch {
      persistenceIssue = "History could not be saved. Keep Alight open to retain this session; check Application Support/Alight permissions."
    }
  }

  private static func valid(_ observation: UsageObservation) -> Bool {
    let window = observation.window
    return observation.capturedAt.timeIntervalSince1970.isFinite &&
      window.resetAt.timeIntervalSince1970.isFinite && window.resetAt > observation.capturedAt &&
      window.usedPercent.isFinite && (0...100).contains(window.usedPercent) &&
      window.limitWindowSeconds.isFinite && window.limitWindowSeconds > 0
  }

  private static var defaultPersistenceURL: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appending(path: "Alight", directoryHint: .isDirectory).appending(path: "usage-history.json")
  }

  private struct Document: Codable {
    let version: Int
    let observations: [UsageObservation]
    // Optional so existing v1 histories without clock fences remain readable.
    let clockDiscontinuities: [String]?
  }
  private enum HistoryError: Error { case invalidDocument }
}

enum UsageForecastUnavailable: String, Sendable {
  case accountUnknown, insufficientCoverage, stale, clockChanged, windowChanged, noConsumption, expired

  var guidance: String {
    switch self {
    case .accountUnknown: "Account continuity is unverified. These live readings are isolated points; a provider-bound account identity is needed for a forecast."
    case .insufficientCoverage: "Collect at least three live readings spanning ten minutes in this uninterrupted quota window."
    case .stale: "The last live reading is over fifteen minutes old. Refresh to rebuild recent coverage."
    case .clockChanged: "The clock moved behind the last reading. Wait for a new live observation."
    case .windowChanged: "The account, source, quota window, or limit changed. New live coverage is needed."
    case .noConsumption: "No consumption was observed in recent coverage. A time to zero cannot be estimated yet."
    case .expired: "This quota window has reset. Refresh for the new window."
    }
  }
}

struct UsageProjection: Sendable {
  let at: Date
  let remainingPercent: Double
  /// Extrapolated demand beyond the current allowance, in percentage points.
  /// This is not billed overage, cost, or permission to consume extra quota.
  let quotaOverrunPoints: Double
}

struct UsageForecast: Sendable {
  static let maximumGap: TimeInterval = 15 * 60
  let window: UsageWindow
  let now: Date
  let ratePointsPerHour: Double?
  let rateRange: ClosedRange<Double>?
  let coverageSeconds: TimeInterval
  let readingCount: Int
  let latestCapturedAt: Date?
  let unavailable: UsageForecastUnavailable?

  init(window: UsageWindow, identity: UsageObservationIdentity?, observations: [UsageObservation], now: Date) {
    self.window = window
    self.now = now
    var reason: UsageForecastUnavailable?
    var rate: Double?
    var range: ClosedRange<Double>?
    var coverage: TimeInterval = 0
    var count = 0
    let last = observations.last { $0.window.id == window.id }
    latestCapturedAt = last?.capturedAt
    if window.resetAt <= now { reason = .expired }
    else if identity == nil || identity?.source.isEmpty == true || identity?.accountPartition.isEmpty == true { reason = .accountUnknown }
    else if let last {
      if last.capturedAt > now { reason = .clockChanged }
      else if now.timeIntervalSince(last.capturedAt) > Self.maximumGap { reason = .stale }
      else if last.identity != identity || last.window.resetAt != window.resetAt ||
        last.window.limitWindowSeconds != window.limitWindowSeconds || last.window.usedPercent != window.usedPercent { reason = .windowChanged }
      else {
        let points = observations.filter { $0.segment == last.segment && $0.capturedAt >= last.capturedAt.addingTimeInterval(-3600) }
        count = points.count
        if let first = points.first { coverage = last.capturedAt.timeIntervalSince(first.capturedAt) }
        let validSeries = points.allSatisfy {
          $0.window.id == window.id && $0.identity == identity &&
          $0.window.resetAt == window.resetAt && $0.window.limitWindowSeconds == window.limitWindowSeconds
        } && zip(points, points.dropFirst()).allSatisfy {
          let gap = $0.1.capturedAt.timeIntervalSince($0.0.capturedAt)
          return gap > 0 && gap <= Self.maximumGap && $0.1.window.usedPercent >= $0.0.window.usedPercent
        }
        if !validSeries { reason = .windowChanged }
        else if count < 3 || coverage < 600 { reason = .insufficientCoverage }
        else {
          let intervals = zip(points, points.dropFirst()).map { pair -> Double in
            (pair.1.window.usedPercent - pair.0.window.usedPercent) * 3600 / pair.1.capturedAt.timeIntervalSince(pair.0.capturedAt)
          }
          let average = (last.window.usedPercent - points[0].window.usedPercent) * 3600 / coverage
          if !average.isFinite || average <= 0 { reason = .noConsumption }
          else {
            rate = average
            range = (intervals.min() ?? average)...(intervals.max() ?? average)
          }
        }
      }
    } else { reason = .insufficientCoverage }
    ratePointsPerHour = rate
    rateRange = range
    coverageSeconds = coverage
    readingCount = count
    unavailable = reason
  }

  /// Pace allowed by the *remaining* allowance until the reported reset, using
  /// the same remaining/reset contract as PressureMath, independent of history.
  var sustainablePointsPerHour: Double? {
    let hours = window.resetAt.timeIntervalSince(now) / 3600
    return hours > 0 ? window.remainingPercent / hours : nil
  }

  var timeToZero: Date? {
    guard let ratePointsPerHour, let latestCapturedAt else { return nil }
    let date = latestCapturedAt.addingTimeInterval(window.remainingPercent / ratePointsPerHour * 3600)
    return date <= window.resetAt ? date : nil
  }

  /// Forecast only inside the current quota window. Calendar week end is not
  /// interchangeable with a provider reset, and never crosses an unknown reset.
  func projection(at horizon: Date) -> UsageProjection? {
    guard let ratePointsPerHour, let latestCapturedAt, horizon >= now, horizon <= window.resetAt else { return nil }
    let projected = window.usedPercent + ratePointsPerHour * horizon.timeIntervalSince(latestCapturedAt) / 3600
    return UsageProjection(at: horizon, remainingPercent: max(0, 100 - projected), quotaOverrunPoints: max(0, projected - 100))
  }
}
