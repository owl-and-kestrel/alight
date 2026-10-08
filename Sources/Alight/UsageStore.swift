import Foundation
import Observation
import OSLog

@Observable
final class UsageStore {
  private static let logger = Logger(subsystem: "com.owlandkestrel.alight", category: "usage")

  private let codex = CodexUsageClient()
  private let claude = ClaudeUsageClient()
  private let antigravity = AntigravityUsageClient()

  var status = UsageStatus()
  var history: UsageHistory

  /// Last successful windows per provider. Only derived usage values are
  /// persisted; provider credentials never enter this cache.
  @ObservationIgnored private var resultCache: UsageResultCache
  /// Scheduled and manual refreshes share one task. `@MainActor` prevents data
  /// races, but without this single-flight gate two actor-isolated calls could
  /// still interleave while their network requests are suspended.
  @ObservationIgnored private var inFlightRefresh: Task<Void, Never>?
  @ObservationIgnored private var forceRefreshPending = false
  @ObservationIgnored private var activeRefreshIsForced = false

  // Each Claude poll starts Claude Code's CLI, so it runs on its own gentle
  // schedule, decoupled from Codex's per-minute cadence. The single-flight
  // refresh above means two Claude polls never overlap.
  @ObservationIgnored private var claudeSchedule = ClaudePollSchedule()

  init(history: UsageHistory = UsageHistory(), resultCache: UsageResultCache = UsageResultCache()) {
    self.history = history
    self.resultCache = resultCache
  }

  @MainActor
  func refresh(force: Bool = false) async {
    if let inFlightRefresh {
      if force && !activeRefreshIsForced {
        forceRefreshPending = true
      }
      await inFlightRefresh.value
      return
    }

    let task = Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      var nextRefreshIsForced = force
      repeat {
        self.forceRefreshPending = false
        self.activeRefreshIsForced = nextRefreshIsForced
        await self.performRefresh(force: nextRefreshIsForced)
        nextRefreshIsForced = self.forceRefreshPending
      } while nextRefreshIsForced
      self.activeRefreshIsForced = false
      self.inFlightRefresh = nil
    }
    inFlightRefresh = task
    await task.value
  }

  @MainActor
  private func performRefresh(force: Bool) async {
    let now = Date()
    // Codex polls every cycle; copy the (Sendable) client into a local so we
    // don't send main-actor `self` across the concurrency boundary.
    let codex = self.codex
    let antigravity = self.antigravity
    async let codexReading = Self.capture { await codex.result(now: now) }
    async let antigravityReading = Self.capture { await antigravity.result(now: now) }

    // Poll Claude only when its gentle cadence/backoff allows.
    let claudeResult: ProviderResult
    var claudeCapturedAt: Date?
    let cacheAgeBeforePoll = resultCache.cacheAge(for: .claude, now: now) ?? -1
    let nextAllowedBeforePoll = max(0, claudeSchedule.nextAllowed.timeIntervalSince(now))
    let isClaudeDue = claudeSchedule.isDue(at: now)
    Self.logger.info(
      "Claude refresh decision force=\(force, privacy: .public) due=\(isClaudeDue, privacy: .public) next_allowed_in=\(nextAllowedBeforePoll, privacy: .public) cache_age=\(cacheAgeBeforePoll, privacy: .public)"
    )
    if force || isClaudeDue {
      let fresh = await claude.result(now: now)
      let capturedAt = Date()
      claudeCapturedAt = capturedAt
      claudeSchedule.record(fresh, at: capturedAt)
      claudeResult = fresh
      Self.logClaudeLiveAttempt(fresh, now: capturedAt, nextAllowed: claudeSchedule.nextAllowed)
    } else {
      // Not due yet: reuse a reset-bounded cache if one exists, and keep the
      // latest attempt's account, sign-in state, and reason rather than
      // pretending this is live.
      claudeResult = claudeSchedule.deferredResult(now: now)
      Self.logger.info(
        "Claude live attempt skipped source=deferred next_allowed_in=\(nextAllowedBeforePoll, privacy: .public) cache_age=\(cacheAgeBeforePoll, privacy: .public)"
      )
    }

    let rawCodex = await codexReading
    let rawAntigravity = await antigravityReading
    // Record successful live values before the cache can turn a failure into
    // an old reading. Timestamp each completion, not the start of the refresh.
    var readings = [rawCodex, rawAntigravity]
    if let claudeCapturedAt { readings.append((claudeResult, claudeCapturedAt)) }
    for reading in readings.sorted(by: { $0.1 < $1.1 }) {
      history.record(reading.0, capturedAt: reading.1)
    }
    let completedAt = Date()
    let reconciledCodex = resultCache.reconcile(rawCodex.0, now: completedAt)
    let reconciledClaude = resultCache.reconcile(claudeResult, now: completedAt)
    let reconciledAntigravity = resultCache.reconcile(rawAntigravity.0, now: completedAt)
    Self.logClaudeStatus(reconciledClaude, now: completedAt)

    status = UsageStatus(
      generatedAt: completedAt,
      results: [reconciledCodex, reconciledClaude, reconciledAntigravity]
    )
  }

  private static func capture(_ operation: @Sendable () async -> ProviderResult) async -> (ProviderResult, Date) {
    let result = await operation()
    return (result, Date())
  }

  private static func logClaudeLiveAttempt(_ result: ProviderResult, now: Date, nextAllowed: Date) {
    let summary = ClaudeWindowLogSummary(result: result, now: now)
    logger.info(
      "Claude live attempt ok=\(result.ok, privacy: .public) source=\(result.source, privacy: .public) needs_auth=\(result.needsAuth, privacy: .public) error=\(result.error ?? "none", privacy: .private) next_allowed_in=\(max(0, nextAllowed.timeIntervalSince(now)), privacy: .public) windows=\(result.windows.count, privacy: .public) fast_used=\(summary.fastUsed, privacy: .public) fast_reset_in=\(summary.fastResetIn, privacy: .public) slow_used=\(summary.slowUsed, privacy: .public) slow_reset_in=\(summary.slowResetIn, privacy: .public)"
    )
  }

  private static func logClaudeStatus(_ result: ProviderResult, now: Date) {
    let summary = ClaudeWindowLogSummary(result: result, now: now)
    logger.info(
      "Claude status ok=\(result.ok, privacy: .public) source=\(result.source, privacy: .public) needs_auth=\(result.needsAuth, privacy: .public) error=\(result.error ?? "none", privacy: .private) cache_age=\(result.cacheAgeSeconds ?? -1, privacy: .public) windows=\(result.windows.count, privacy: .public) fast_used=\(summary.fastUsed, privacy: .public) fast_reset_in=\(summary.fastResetIn, privacy: .public) slow_used=\(summary.slowUsed, privacy: .public) slow_reset_in=\(summary.slowResetIn, privacy: .public)"
    )
  }
}

/// When Claude Code is next asked for usage, and what the menu shows until then.
///
/// - Success: every three minutes.
/// - Signed out (`auth status` said so): every minute. Only that local check
///   runs (about 0.2 s), and usage is read as soon as the user signs in.
/// - Any other failure: three minutes, doubling to fifteen.
/// - Refusal (Claude Code answered `/usage` with a model turn): no scheduled
///   polls until a manual Refresh, so a changed CLI cannot spend inference
///   every poll.
///
/// Between polls, `deferredResult` carries the latest attempt's account,
/// sign-in state, and failure reason, so the menu keeps offering Sign in to
/// Claude… and the cache only reuses readings from the account last verified.
struct ClaudePollSchedule {
  static let baseInterval: TimeInterval = 180
  static let maxBackoff: TimeInterval = 900
  static let signedOutInterval: TimeInterval = 60

  private(set) var nextAllowed: Date = .distantPast
  private(set) var backoff: TimeInterval = 0
  private(set) var lastAttempt: ProviderResult?

  func isDue(at now: Date) -> Bool {
    now >= nextAllowed
  }

  mutating func record(_ attempt: ProviderResult, at now: Date) {
    lastAttempt = attempt
    if attempt.ok {
      backoff = 0
      nextAllowed = now.addingTimeInterval(Self.baseInterval)
    } else if attempt.source == ClaudeUsageClient.refusedSource {
      backoff = 0
      nextAllowed = .distantFuture
    } else if attempt.source == ClaudeUsageClient.signedOutSource {
      backoff = 0
      nextAllowed = now.addingTimeInterval(Self.signedOutInterval)
    } else {
      backoff = backoff == 0 ? Self.baseInterval : min(Self.maxBackoff, backoff * 2)
      nextAllowed = now.addingTimeInterval(backoff)
    }
  }

  func deferredResult(now: Date) -> ProviderResult {
    let wait = nextAllowed == .distantFuture
      ? nil
      : ProviderResult.compactDuration(max(0, nextAllowed.timeIntervalSince(now)))
    let error: String
    if let lastAttempt, !lastAttempt.ok, let reason = lastAttempt.error {
      // A refusal's reason already says to update and Refresh.
      error = wait.map { "\(reason) · retry in \($0)" } ?? reason
    } else {
      error = wait.map { "next live poll in \($0)" } ?? "Claude polling stopped; Refresh to retry"
    }
    return .failure(
      .claude,
      source: "deferred",
      error: error,
      needsAuth: lastAttempt?.needsAuth ?? false,
      observationIdentity: lastAttempt?.observationIdentity
    )
  }
}

struct UsageResultCache: Sendable {
  private var lastGood: [Provider: CachedUsageReading] = [:]
  private let persistenceURL: URL?
  private let antigravitySourceIdentity: String

  init(
    persistenceURL: URL? = UsageResultCache.defaultPersistenceURL,
    antigravitySourceIdentity: String = AntigravityUsageSource.cacheIdentity()
  ) {
    self.persistenceURL = persistenceURL
    self.antigravitySourceIdentity = antigravitySourceIdentity
    guard let persistenceURL else {
      return
    }
    do {
      let data = try Data(contentsOf: persistenceURL)
      let document = try JSONDecoder.alight.decode(PersistedUsageCache.self, from: data)
      guard document.version == PersistedUsageCache.currentVersion else {
        return
      }
      lastGood = document.readings.reduce(into: [:]) { result, entry in
        guard let provider = Provider(rawValue: entry.key) else {
          return
        }
        // Legacy Antigravity readings lack provenance. Never relabel those, or
        // a different endpoint's balance, as the current runtime's quota.
        if provider == .antigravity, entry.value.sourceIdentity != antigravitySourceIdentity {
          return
        }
        // Claude readings are bound to the account that produced them. Older
        // unbound readings may belong to a previous login; drop them.
        if provider == .claude, entry.value.sourceIdentity == nil {
          return
        }
        result[provider] = entry.value
      }
    } catch {
      // Missing, corrupt, or old cache files are non-fatal. A future successful
      // provider response will atomically replace them.
      lastGood = [:]
    }
  }

  /// Validates a persisted cache using the same Codable schema as the runtime
  /// reader. Rename migration uses this instead of guessing at JSON fields.
  static func isValidPersistedCache(at url: URL) -> Bool {
    do {
      let data = try Data(contentsOf: url)
      let document = try JSONDecoder.alight.decode(PersistedUsageCache.self, from: data)
      return document.version == PersistedUsageCache.currentVersion && !document.readings.isEmpty
    } catch {
      return false
    }
  }

  func cacheAge(for provider: Provider, now: Date) -> TimeInterval? {
    guard let cached = lastGood[provider] else {
      return nil
    }
    return max(0, now.timeIntervalSince(cached.capturedAt))
  }

  /// Fold a fresh poll against the last-good cache. Successful readings refresh
  /// the cache. Any later failure may reuse a last-known window until that
  /// window's own reset boundary, and for at most `maxCacheAge`, while
  /// preserving the current error/auth state in the menu. This keeps
  /// availability separate from data freshness without pretending an old
  /// reading is live.
  ///
  /// Claude readings are reused only for the same verified account: a result
  /// whose account is unknown or different drops the cached Claude reading.
  mutating func reconcile(_ result: ProviderResult, now: Date) -> ProviderResult {
    let claudeAccount = result.provider == .claude ? Self.claudeAccountKey(result.observationIdentity) : nil
    if result.provider == .claude, claudeAccount == nil || lastGood[.claude]?.sourceIdentity != claudeAccount {
      if lastGood.removeValue(forKey: .claude) != nil {
        persist()
      }
    }

    if result.ok, !result.windows.isEmpty {
      // An unidentified Claude reading is shown live but never cached.
      if result.provider == .claude, claudeAccount == nil {
        return result
      }
      // Reuse the latest successful response during deferred/transient cycles,
      // including scoped limits such as Fable. A later successful response that
      // omits a scoped limit naturally replaces the cache and clears the marker.
      let sourceIdentity: String? = switch result.provider {
      case .antigravity: antigravitySourceIdentity
      case .claude: claudeAccount
      case .codex: nil
      }
      lastGood[result.provider] = CachedUsageReading(
        windows: result.windows,
        capturedAt: now,
        sourceIdentity: sourceIdentity
      )
      persist()
      return result
    }

    guard let cached = lastGood[result.provider], !cached.windows.isEmpty else {
      return result
    }

    let age = max(0, now.timeIntervalSince(cached.capturedAt))
    // A reading older than `maxCacheAge` is no longer a useful stand-in for live
    // usage, even before its window resets (a 38h-old "93% left" misled).
    let validWindows = age > Self.maxCacheAge ? [] : cached.windows
      .filter { $0.resetAt > now }
      .map { Self.rebased($0, now: now) }

    guard !validWindows.isEmpty else {
      lastGood.removeValue(forKey: result.provider)
      persist()
      return ProviderResult.failure(
        result.provider,
        source: result.source,
        error: Self.messageWithLastLive(result.error, age: age),
        needsAuth: result.needsAuth,
        cacheAgeSeconds: age
      )
    }

    return ProviderResult(
      provider: result.provider,
      ok: true,
      source: "cached",
      error: result.error,
      windows: validWindows,
      needsAuth: result.needsAuth,
      cacheAgeSeconds: age,
      observationIdentity: result.observationIdentity
    )
  }

  /// Oldest cached reading that may still be shown while live polls fail.
  static let maxCacheAge: TimeInterval = 6 * 3600

  /// The persisted Claude binding: the domain-separated account digest plus the plan.
  /// Never a raw email or organization id.
  static func claudeAccountKey(_ identity: UsageObservationIdentity?) -> String? {
    guard let identity, identity.source == ClaudeUsageClient.identitySource,
      !identity.accountPartition.isEmpty else {
      return nil
    }
    return identity.accountPartition + "/" + (identity.limitIdentity ?? "")
  }

  private static func messageWithLastLive(_ error: String?, age: TimeInterval) -> String {
    let base = error ?? "usage unavailable"
    return "\(base); last live \(ProviderResult.compactDuration(age)) ago"
  }

  private static func rebased(_ window: UsageWindow, now: Date) -> UsageWindow {
    PressureMath.window(
      provider: window.provider,
      // Older caches may contain a weekly Codex primary window that was
      // serialized as `.fast`. Repair it from the provider-reported duration
      // while rebasing instead of preserving the old positional assumption.
      speed: window.provider == .codex
        ? .cadence(for: window.limitWindowSeconds)
        : window.speed,
      usedPercent: window.usedPercent,
      resetAt: window.resetAt,
      limitWindowSeconds: window.limitWindowSeconds,
      now: now,
      scope: window.scope,
      visualStyle: window.visualStyle
    )
  }

  private mutating func persist() {
    guard let persistenceURL else {
      return
    }
    let document = PersistedUsageCache(
      version: PersistedUsageCache.currentVersion,
      readings: Dictionary(uniqueKeysWithValues: lastGood.map { ($0.key.rawValue, $0.value) })
    )

    do {
      let directory = persistenceURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
      )
      let data = try JSONEncoder.alight.encode(document)
      try data.write(to: persistenceURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: persistenceURL.path
      )
    } catch {
      // Cache persistence is a resilience aid. A filesystem error must never
      // prevent live usage from reaching the menu.
    }
  }

  private static var defaultPersistenceURL: URL {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support")
    return base
      .appending(path: "Alight", directoryHint: .isDirectory)
      .appending(path: "usage-cache.json")
  }

}

private struct PersistedUsageCache: Codable, Sendable {
  static let currentVersion = 1

  let version: Int
  let readings: [String: CachedUsageReading]
}

private struct CachedUsageReading: Codable, Sendable {
  let windows: [UsageWindow]
  let capturedAt: Date
  /// Provenance a reading must match to be reused: Antigravity's endpoint
  /// fingerprint, or Claude's account key. Nil for Codex.
  let sourceIdentity: String?
}

private extension JSONEncoder {
  static var alight: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

private extension JSONDecoder {
  static var alight: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

private struct ClaudeWindowLogSummary {
  let fastUsed: Double
  let fastResetIn: TimeInterval
  let slowUsed: Double
  let slowResetIn: TimeInterval

  init(result: ProviderResult, now: Date) {
    // Broad windows only; a Team seat's scoped Fable week is not its weekly limit.
    let fast = result.windows.first { $0.provider == .claude && $0.speed == .fast && $0.scope == nil }
    let slow = result.windows.first { $0.provider == .claude && $0.speed == .slow && $0.scope == nil }
    fastUsed = fast?.usedPercent ?? -1
    fastResetIn = fast.map { max(0, $0.resetAt.timeIntervalSince(now)) } ?? -1
    slowUsed = slow?.usedPercent ?? -1
    slowResetIn = slow.map { max(0, $0.resetAt.timeIntervalSince(now)) } ?? -1
  }
}
