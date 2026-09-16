import Foundation

/// A usage backend Alight tracks. Each provider contributes a fast and a
/// slow window, and is distinguished on the dial by hand color.
enum Provider: String, Codable, CaseIterable, Sendable {
  case codex
  case claude
  case antigravity

  var displayName: String {
    switch self {
    case .codex: "Codex"
    case .claude: "Claude"
    case .antigravity: "Antigravity"
    }
  }
}

/// The two visual lanes used by the gauge. Providers do not necessarily expose
/// both lanes: Codex, for example, may currently return only a weekly window.
/// The API-reported duration decides the lane; payload field names do not.
enum WindowSpeed: String, Codable, Sendable {
  case fast
  case slow

  static func cadence(for duration: TimeInterval) -> WindowSpeed {
    duration >= 24 * 60 * 60 ? .slow : .fast
  }
}

enum UsageVisualStyle: String, Codable, Sendable {
  case hand
  case outerStar
  /// Dropdown-only rows for scoped limits beyond Fable. They draw nothing on
  /// the dial: the four-pointed star remains the sole scoped marker until
  /// marker styles for further scoped models are decided.
  case menuRow
}

struct UsageScope: Codable, Hashable, Sendable {
  let kind: String
  let key: String
  let displayName: String

  static let fable = UsageScope(kind: "model", key: "fable", displayName: "Fable")

  /// Deterministic scope identity for a provider-reported model name. Returns
  /// nil for names without usable identity so callers fail closed instead of
  /// colliding with an invented key.
  static func modelScope(displayName rawName: String) -> UsageScope? {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      return nil
    }
    var slug = ""
    var previousWasSeparator = true
    for scalar in name.lowercased().unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        slug.unicodeScalars.append(scalar)
        previousWasSeparator = false
      } else if !previousWasSeparator {
        slug.append("-")
        previousWasSeparator = true
      }
    }
    if slug.hasSuffix("-") {
      slug.removeLast()
    }
    guard !slug.isEmpty else {
      return nil
    }
    return UsageScope(kind: "model", key: slug, displayName: name)
  }
}

enum PressureBand: String, Codable, Sendable {
  case high
  case good
  case low
  case unknown

  init(pressurePercent: Double) {
    if pressurePercent > 5 {
      self = .high
    } else if pressurePercent < -5 {
      self = .low
    } else {
      self = .good
    }
  }

  var label: String {
    switch self {
    case .high:
      "High"
    case .good:
      "Good"
    case .low:
      "Low"
    case .unknown:
      "Unknown"
    }
  }
}

struct UsageWindow: Codable, Identifiable, Sendable {
  let provider: Provider
  let speed: WindowSpeed
  let scope: UsageScope?
  let visualStyle: UsageVisualStyle
  let usedPercent: Double
  let remainingPercent: Double
  let expectedRemainingPercent: Double
  let pressurePercent: Double
  let resetAt: Date
  let limitWindowSeconds: TimeInterval

  var id: String {
    let scopeKey = scope.map { "_\($0.kind)_\($0.key)" } ?? ""
    return "\(provider.rawValue)_\(speed.rawValue)\(scopeKey)"
  }

  /// Short label for the dropdown ("5h", "Weekly", "Fable"). The provider's
  /// reported duration is authoritative so a weekly `primary_window` can never
  /// be mislabeled as a five-hour limit.
  var label: String { scope?.displayName ?? Self.durationLabel(limitWindowSeconds) }

  /// Provider-qualified label for the menu-bar summary ("Codex 5h").
  var qualifiedLabel: String { "\(provider.displayName) \(label)" }

  var band: PressureBand {
    PressureBand(pressurePercent: pressurePercent)
  }

  var remainingDisplay: String {
    "\(Int(remainingPercent.rounded()))%"
  }

  var pressureDisplay: String {
    let rounded = Int(pressurePercent.rounded())
    return rounded > 0 ? "+\(rounded)%" : "\(rounded)%"
  }

  /// Local wall-clock reset plus a compact countdown for the clickthrough.
  /// The menu refreshes once a minute, so minute precision is intentional.
  func resetDescription(now: Date) -> String {
    let absolute = resetAt.formatted(
      .dateTime.weekday(.abbreviated).hour().minute()
    )
    return "\(absolute) (\(resetCountdown(now: now)))"
  }

  func resetCountdown(now: Date) -> String {
    Self.compactResetCountdown(resetAt.timeIntervalSince(now))
  }

  static func compactResetCountdown(_ seconds: TimeInterval) -> String {
    guard seconds > 0 else {
      return "now"
    }

    let totalMinutes = max(1, Int(ceil(seconds / 60)))
    let days = totalMinutes / (24 * 60)
    let hours = (totalMinutes % (24 * 60)) / 60
    let minutes = totalMinutes % 60

    if days > 0 {
      return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
    }
    if hours > 0 {
      return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    }
    return "\(minutes)m"
  }

  private static func durationLabel(_ seconds: TimeInterval) -> String {
    let minutes = max(1, Int((seconds / 60).rounded()))
    if minutes == 7 * 24 * 60 {
      return "Weekly"
    }
    if minutes.isMultiple(of: 24 * 60) {
      return "\(minutes / (24 * 60))d"
    }
    if minutes.isMultiple(of: 60) {
      return "\(minutes / 60)h"
    }
    return "\(minutes)m"
  }
}

/// The outcome of polling a single provider. Kept even when empty so the menu
/// can explain *why* a provider has no hands (expired token, fetch error).
struct ProviderResult: Sendable {
  let provider: Provider
  let ok: Bool
  let source: String
  let error: String?
  let windows: [UsageWindow]
  /// True when the failure is a credential problem the user can fix by signing
  /// in (vs. a transient network/rate-limit error).
  var needsAuth: Bool = false
  /// Age of the live reading being reused for a cached result, when known.
  var cacheAgeSeconds: TimeInterval? = nil
  /// Server-provided retry delay for transient failures such as HTTP 429.
  var retryAfterSeconds: TimeInterval? = nil

  var cacheAgeDisplay: String? {
    cacheAgeSeconds.map(Self.compactDuration)
  }

  var sourceLabel: String? {
    guard source == "cached" else {
      return nil
    }
    if let cacheAgeDisplay {
      return "cached \(cacheAgeDisplay)"
    }
    return "cached"
  }

  static func failure(
    _ provider: Provider,
    source: String,
    error: String,
    needsAuth: Bool = false,
    cacheAgeSeconds: TimeInterval? = nil,
    retryAfterSeconds: TimeInterval? = nil
  ) -> ProviderResult {
    ProviderResult(
      provider: provider,
      ok: false,
      source: source,
      error: error,
      windows: [],
      needsAuth: needsAuth,
      cacheAgeSeconds: cacheAgeSeconds,
      retryAfterSeconds: retryAfterSeconds
    )
  }

  static func compactDuration(_ seconds: TimeInterval) -> String {
    let wholeSeconds = max(0, Int(seconds.rounded()))
    if wholeSeconds < 90 {
      return "\(wholeSeconds)s"
    }

    let minutes = max(1, wholeSeconds / 60)
    if minutes < 90 {
      return "\(minutes)m"
    }

    let hours = max(1, minutes / 60)
    if hours < 48 {
      return "\(hours)h"
    }

    return "\(max(1, hours / 24))d"
  }
}

struct UsageStatus: Sendable {
  var generatedAt: Date = .now
  var results: [ProviderResult] = []

  var windows: [UsageWindow] {
    results.flatMap(\.windows)
  }

  var ok: Bool { !windows.isEmpty }

  func result(for provider: Provider) -> ProviderResult? {
    results.first { $0.provider == provider }
  }

  func window(provider: Provider, speed: WindowSpeed) -> UsageWindow? {
    windows.first { $0.provider == provider && $0.speed == speed && $0.scope == nil }
  }

  /// The most constrained window across every provider — the one with the
  /// lowest pace pressure.
  var worst: UsageWindow? {
    windows.min { $0.pressurePercent < $1.pressurePercent }
  }

  var summary: String {
    guard let worst else {
      return "Alight: usage unavailable"
    }
    let sourceSuffix = result(for: worst.provider)?.sourceLabel.map { " (\($0))" } ?? ""
    let reset = worst.resetCountdown(now: generatedAt)
    return "\(worst.qualifiedLabel) \(worst.pressureDisplay) \(worst.band.label.lowercased())\(sourceSuffix) · resets in \(reset)"
  }
}

/// Shared normalization so both provider clients derive pace pressure the same
/// way. `usedPercent` is 0–100; the caller is responsible for unit conversion.
enum PressureMath {
  static func window(
    provider: Provider,
    speed: WindowSpeed,
    usedPercent: Double,
    resetAt: Date,
    limitWindowSeconds: TimeInterval,
    now: Date,
    scope: UsageScope? = nil,
    visualStyle: UsageVisualStyle = .hand
  ) -> UsageWindow {
    let used = min(100, max(0, usedPercent))
    let secondsRemaining = max(0, resetAt.timeIntervalSince(now))
    let duration = max(60, limitWindowSeconds)
    let expectedRemaining = min(1, max(0, secondsRemaining / duration))
    let actualRemaining = min(1, max(0, 1 - used / 100))
    let pressure = actualRemaining - expectedRemaining

    return UsageWindow(
      provider: provider,
      speed: speed,
      scope: scope,
      visualStyle: visualStyle,
      usedPercent: used,
      remainingPercent: actualRemaining * 100,
      expectedRemainingPercent: expectedRemaining * 100,
      pressurePercent: pressure * 100,
      resetAt: resetAt,
      limitWindowSeconds: duration
    )
  }
}
