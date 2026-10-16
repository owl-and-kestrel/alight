import Foundation

/// Swift mirror of Fieldbook's `ok.fieldbook.quota-observation.v1` (Fieldbook
/// `src/quota/observation.mjs`, pinned in scripts/build-core.mjs). Alight is a
/// producer of these records; their validation and pace math run from
/// Fieldbook's own code through `CoreScript`.
struct QuotaObservation: Codable, Equatable, Sendable {
  static let contract = "ok.fieldbook.quota-observation.v1"

  struct Parser: Codable, Equatable, Sendable {
    var id: String
    var version: Int
  }

  struct Window: Codable, Equatable, Sendable {
    var windowId: String
    var label: String
    var usedFraction: Double
    var remainingFraction: Double
    var resetsAt: String
    var resetPrecision: String
    var windowSeconds: Double
    var observedAt: String
    var source: String
    var rawSha256: String?
    var inferred: [String]
    var unknown: [String]

    // Fieldbook's records always carry `rawSha256`, null when absent.
    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(windowId, forKey: .windowId)
      try container.encode(label, forKey: .label)
      try container.encode(usedFraction, forKey: .usedFraction)
      try container.encode(remainingFraction, forKey: .remainingFraction)
      try container.encode(resetsAt, forKey: .resetsAt)
      try container.encode(resetPrecision, forKey: .resetPrecision)
      try container.encode(windowSeconds, forKey: .windowSeconds)
      try container.encode(observedAt, forKey: .observedAt)
      try container.encode(source, forKey: .source)
      try container.encode(rawSha256, forKey: .rawSha256)
      try container.encode(inferred, forKey: .inferred)
      try container.encode(unknown, forKey: .unknown)
    }
  }

  var contract: String = Self.contract
  var routeId: String
  var poolId: String
  var source: String
  var parser: Parser
  var observedAt: String?
  var rawSha256: String?
  var status: String
  var windows: [Window]
  var unknown: [String]
  var reasons: [String]

  // `observedAt` and `rawSha256` are always present, null when unknown.
  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(contract, forKey: .contract)
    try container.encode(routeId, forKey: .routeId)
    try container.encode(poolId, forKey: .poolId)
    try container.encode(source, forKey: .source)
    try container.encode(parser, forKey: .parser)
    try container.encode(observedAt, forKey: .observedAt)
    try container.encode(rawSha256, forKey: .rawSha256)
    try container.encode(status, forKey: .status)
    try container.encode(windows, forKey: .windows)
    try container.encode(unknown, forKey: .unknown)
    try container.encode(reasons, forKey: .reasons)
  }

  /// Millisecond ISO-8601 in UTC, exactly as JavaScript's `toISOString`.
  /// Formatted from whole milliseconds so a parsed timestamp re-encodes to
  /// itself (a Double's fraction would otherwise drift down a millisecond).
  static func timestamp(_ date: Date) -> String {
    let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
    let seconds = Int64((Double(milliseconds) / 1000).rounded(.down))
    let whole = Date(timeIntervalSince1970: TimeInterval(seconds))
      .formatted(Date.ISO8601FormatStyle().year().month().day().dateTimeSeparator(.standard).time(includingFractionalSeconds: false))
    return "\(whole).\(String(format: "%03lld", milliseconds - seconds * 1000))Z"
  }

  static func date(_ timestamp: String) -> Date? {
    guard let parsed = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp))
      ?? (try? Date.ISO8601FormatStyle().parse(timestamp))
    else { return nil }
    return Date(timeIntervalSince1970: (parsed.timeIntervalSince1970 * 1000).rounded() / 1000)
  }
}

/// How Alight's readings become quota observations, and back. The record is
/// the source of truth: live windows shown in the app are decoded from the
/// record that was logged, so the display and the history agree exactly.
enum AlightQuotaProducer {
  struct Route: Equatable, Sendable {
    let routeId: String
    let poolId: String
    let source: String
    let parser: QuotaObservation.Parser
    let resetPrecision: String
  }

  static func route(for provider: Provider) -> Route {
    switch provider {
    case .codex:
      Route(routeId: "api:chatgpt-codex", poolId: "codex-subscription", source: "alight:chatgpt-wham-usage",
        parser: .init(id: "alight.codex-usage", version: 1), resetPrecision: "second")
    case .claude:
      // Fieldbook's own Claude normalizer uses this route and pool.
      Route(routeId: "cli:claude-code", poolId: "claude-subscription", source: "alight:claude-code-usage",
        parser: .init(id: "alight.claude-usage-text", version: 1), resetPrecision: "minute")
    case .antigravity:
      Route(routeId: "api:antigravity-quota-summary", poolId: "antigravity-quota", source: "alight:antigravity-quota-summary",
        parser: .init(id: "alight.antigravity-quota", version: 1), resetPrecision: "second")
    }
  }

  static func provider(routeId: String) -> Provider? {
    Provider.allCases.first { route(for: $0).routeId == routeId }
  }

  /// `session` and `week` (Fieldbook's names) for broad limits;
  /// `<scope kind>:<scope key>` for scoped ones.
  static func windowId(_ window: UsageWindow) -> String {
    if let scope = window.scope { return "\(scope.kind):\(scope.key)" }
    return window.speed == .fast ? "session" : "week"
  }

  /// The observation for a successful live reading; nil otherwise. Only
  /// derived values: no credentials, raw payloads or account identifiers.
  static func observation(for result: ProviderResult, capturedAt: Date) -> QuotaObservation? {
    guard result.ok, result.source == "live", result.cacheAgeSeconds == nil, !result.windows.isEmpty else { return nil }
    let route = route(for: result.provider)
    let observedAt = QuotaObservation.timestamp(capturedAt)
    let windows = result.windows.map { window in
      let used = min(1, max(0, window.usedPercent / 100))
      return QuotaObservation.Window(
        windowId: windowId(window),
        label: window.scope?.displayName ?? window.label,
        usedFraction: used,
        remainingFraction: 1 - used,
        resetsAt: QuotaObservation.timestamp(window.resetAt),
        resetPrecision: route.resetPrecision,
        windowSeconds: window.limitWindowSeconds,
        observedAt: observedAt,
        source: route.source,
        rawSha256: nil,
        inferred: [],
        unknown: []
      )
    }
    return QuotaObservation(
      routeId: route.routeId, poolId: route.poolId, source: route.source, parser: route.parser,
      observedAt: observedAt, rawSha256: nil, status: "observed", windows: windows,
      // A provider can hold quotas its readout does not list.
      unknown: ["unreported_windows"], reasons: []
    )
  }

  /// Alight windows for an observation, with pace as of `now`.
  static func windows(from observation: QuotaObservation, now: Date) -> [UsageWindow] {
    guard let provider = provider(routeId: observation.routeId) else { return [] }
    return observation.windows.compactMap { record in
      guard let resetAt = QuotaObservation.date(record.resetsAt), record.windowSeconds > 0 else { return nil }
      let speed = WindowSpeed.cadence(for: record.windowSeconds)
      var scope: UsageScope?
      var style = UsageVisualStyle.hand
      if let separator = record.windowId.firstIndex(of: ":") {
        let kind = String(record.windowId[..<separator])
        let key = String(record.windowId[record.windowId.index(after: separator)...])
        scope = kind == UsageScope.fable.kind && key == UsageScope.fable.key
          ? .fable
          : UsageScope(kind: kind, key: key, displayName: record.label)
        style = scope == .fable ? .outerStar : .menuRow
      }
      return PressureMath.window(
        provider: provider, speed: speed, usedPercent: record.usedFraction * 100, resetAt: resetAt,
        limitWindowSeconds: record.windowSeconds, now: now, scope: scope, visualStyle: style
      )
    }
  }
}

extension CoreScript {
  /// Fieldbook's `quotaObservationProblems`: empty when the record is valid.
  func quotaObservationProblems(_ observation: QuotaObservation) throws -> [String] {
    let json = String(decoding: try JSONEncoder().encode(observation), as: UTF8.self)
    return try JSONDecoder().decode([String].self, from: Data(callString("quotaObservationProblemsJSON", [json]).utf8))
  }

  /// Fieldbook's `quotaWindowPace` per window. Alight's percentage windows are
  /// a 100-unit allowance; the linear curve with no reserve is Alight's pace.
  func quotaWindowPace(_ windows: [UsageWindow], now: Date, policy: [String: String] = ["curve": "linear"]) throws -> [FieldbookPace?] {
    struct AstraWindow: Encodable {
      let requests_remaining: Double
      let requests_limit: Double
      let reset_time: String
      let window_duration_seconds: Double
    }
    let input = windows.map {
      AstraWindow(
        requests_remaining: 100 - $0.usedPercent, requests_limit: 100,
        reset_time: QuotaObservation.timestamp($0.resetAt), window_duration_seconds: $0.limitWindowSeconds
      )
    }
    let windowsJSON = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
    let policyJSON = String(decoding: try JSONEncoder().encode(policy), as: UTF8.self)
    let output = try callString("quotaWindowPaceJSON", [windowsJSON, policyJSON, now.timeIntervalSince1970 * 1000])
    return try JSONDecoder().decode([LossyPace].self, from: Data(output.utf8)).map(\.pace)
  }
}

/// The fields of Fieldbook's pace result Alight shows.
struct FieldbookPace: Decodable, Equatable, Sendable {
  let remainingRatio: Double
  let expectedRemainingRatio: Double
  let pressurePercent: Double
  let band: String

  private enum CodingKeys: String, CodingKey {
    case remainingRatio = "remaining_ratio"
    case expectedRemainingRatio = "expected_remaining_ratio"
    case pressurePercent = "pressure_percent"
    case band
  }
}

/// An empty JSON object (a window Fieldbook cannot pace) decodes as nil.
private struct LossyPace: Decodable {
  let pace: FieldbookPace?
  init(from decoder: Decoder) throws {
    pace = try? FieldbookPace(from: decoder)
  }
}
