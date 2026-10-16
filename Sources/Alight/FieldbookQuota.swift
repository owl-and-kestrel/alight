import Foundation

/// What Fieldbook's `normalizeAlightQuotaSnapshot` (src/quota/alight-snapshot.mjs,
/// pinned in scripts/build-core.mjs) returns for one `ok.alight.quota-snapshot.v1`:
/// the snapshot's reading as Fieldbook records it. Only the fields Alight
/// shows are mirrored; Fieldbook owns the mapping itself.
struct FieldbookAlightReading: Decodable, Equatable, Sendable {
  struct ProviderReading: Decodable, Equatable, Sendable {
    let provider: Provider
    /// The snapshot's status for this provider (`observed`, `failed`, ...).
    let status: String
    let usage: FieldbookProviderUsage
  }

  /// `observed`, or `unknown` with `reasons` (stale, invalid, regression).
  let status: String
  let reasons: [String]
  let sequence: Int?
  let providers: [ProviderReading]

  func usage(for provider: Provider) -> FieldbookProviderUsage? {
    providers.first { $0.provider == provider && $0.usage.status == "observed" }?.usage
  }
}

/// Mirror of `ok.fieldbook.provider-usage.v1` (src/quota/provider-usage.mjs).
struct FieldbookProviderUsage: Decodable, Equatable, Sendable {
  struct Scope: Decodable, Equatable, Sendable {
    let kind: String
    let key: String
    let displayName: String
  }

  struct Window: Decodable, Equatable, Sendable {
    let windowId: String
    let scope: Scope?
    let usedPct: Double
    let resetAt: String?
    let resetSource: String
    let windowSeconds: Double?
    let observedAt: String
  }

  let provider: Provider
  let status: String
  let observedAt: String?
  let accountRef: String?
  let windows: [Window]
  let reasons: [String]

  /// Alight's windows for this usage. A window the provider has not started
  /// (no reset reported, nothing used) resets one window after the reading,
  /// as Alight's clients read it; any other window without a reset or a
  /// duration cannot be placed and is left out. A provider group's windows
  /// are secondary (dashboard-only) beside the provider's broad limits, but
  /// when a provider reports only group windows (an Antigravity account with
  /// no Gemini group) they are its limits and draw in the menu bar.
  func usageWindows() -> [UsageWindow] {
    let hasBroadLimits = windows.contains { $0.scope == nil }
    return windows.compactMap { window in
      guard let seconds = window.windowSeconds, seconds > 0, let observedAt = FieldbookTime.date(window.observedAt) else { return nil }
      let resetAt: Date
      if let reported = window.resetAt.flatMap(FieldbookTime.date) {
        resetAt = reported
      } else if window.usedPct == 0 {
        resetAt = observedAt.addingTimeInterval(seconds)
      } else {
        return nil
      }
      var scope: UsageScope?
      var style = UsageVisualStyle.hand
      if let reported = window.scope {
        scope = reported.kind == UsageScope.fable.kind && reported.key == UsageScope.fable.key
          ? .fable
          : UsageScope(kind: reported.kind, key: reported.key, displayName: reported.displayName)
        if scope == .fable {
          style = .outerStar
        } else if reported.kind == "group", !hasBroadLimits {
          style = .hand
        } else {
          style = .menuRow
        }
      }
      return PressureMath.window(
        provider: provider, speed: .cadence(for: seconds), usedPercent: window.usedPct, resetAt: resetAt,
        limitWindowSeconds: seconds, now: observedAt, scope: scope, visualStyle: style
      )
    }
  }
}

/// Fieldbook's timestamps: millisecond ISO-8601 in UTC, as JavaScript's
/// `toISOString` writes them.
enum FieldbookTime {
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

extension CoreScript {
  /// Fieldbook's `normalizeAlightQuotaSnapshot` for an encoded snapshot,
  /// read at `readAt` (the snapshot's own `writtenAt` when replaying).
  func normalizeAlightQuotaSnapshot(_ snapshot: Data, readAt: Date) throws -> FieldbookAlightReading {
    let output = try callString(
      "normalizeAlightQuotaSnapshotJSON",
      [String(decoding: snapshot, as: UTF8.self), (readAt.timeIntervalSince1970 * 1000).rounded()]
    )
    return try JSONDecoder().decode(FieldbookAlightReading.self, from: Data(output.utf8))
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
        reset_time: FieldbookTime.timestamp($0.resetAt), window_duration_seconds: $0.limitWindowSeconds
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
