import Foundation
import Observation
import OSLog

@Observable
final class UsageStore {
  private static let logger = Logger(subsystem: "com.owlandkestrel.glideslope", category: "usage")

  private let codex = CodexUsageClient()
  private let claude = ClaudeUsageClient()
  private let antigravity = AntigravityUsageClient()

  var status = UsageStatus()

  /// Last successful windows per provider. Only derived usage values are
  /// persisted; provider credentials never enter this cache.
  @ObservationIgnored private var resultCache = UsageResultCache()
  /// Scheduled and manual refreshes share one task. `@MainActor` prevents data
  /// races, but without this single-flight gate two actor-isolated calls could
  /// still interleave while their network requests are suspended.
  @ObservationIgnored private var inFlightRefresh: Task<Void, Never>?
  @ObservationIgnored private var forceRefreshPending = false
  @ObservationIgnored private var activeRefreshIsForced = false

  // Claude's usage endpoint rate-limits aggressively (it's meant for on-demand
  // `/usage` lookups, not a 60s poll), so we poll it gently and back off hard
  // on failure, decoupled from Codex's per-minute cadence.
  private static let claudeBaseInterval: TimeInterval = 300
  private static let claudeAuthRetryInterval: TimeInterval = 60
  private static let claudeMaxBackoff: TimeInterval = 900
  private var claudeNextAllowed: Date = .distantPast
  private var claudeBackoff: TimeInterval = 0

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
    async let codexResult = codex.result(now: now)
    async let antigravityResult = antigravity.result(now: now)

    // Poll Claude only when its gentle cadence/backoff allows.
    let claudeResult: ProviderResult
    let cacheAgeBeforePoll = resultCache.cacheAge(for: .claude, now: now) ?? -1
    let nextAllowedBeforePoll = max(0, claudeNextAllowed.timeIntervalSince(now))
    let isClaudeDue = now >= claudeNextAllowed
    Self.logger.info(
      "Claude refresh decision force=\(force, privacy: .public) due=\(isClaudeDue, privacy: .public) next_allowed_in=\(nextAllowedBeforePoll, privacy: .public) cache_age=\(cacheAgeBeforePoll, privacy: .public)"
    )
    if force || isClaudeDue {
      let fresh = await claude.result(now: now)
      if fresh.ok {
        claudeBackoff = 0
        claudeNextAllowed = now.addingTimeInterval(Self.claudeBaseInterval)
      } else if fresh.needsAuth {
        // Credential failures are usually fixed outside Glideslope by opening
        // Claude Code or signing in. Re-check the local credential soon instead
        // of hiding behind the generic network backoff.
        claudeBackoff = 0
        claudeNextAllowed = now.addingTimeInterval(Self.claudeAuthRetryInterval)
      } else if let retryAfter = fresh.retryAfterSeconds {
        // Anthropic returns a precise Retry-After for the usage endpoint. Honor
        // it instead of stretching a short rate-limit into our generic backoff.
        claudeBackoff = 0
        claudeNextAllowed = now.addingTimeInterval(max(5, retryAfter))
      } else {
        claudeBackoff = claudeBackoff == 0
          ? Self.claudeBaseInterval
          : min(Self.claudeMaxBackoff, claudeBackoff * 2)
        claudeNextAllowed = now.addingTimeInterval(claudeBackoff)
      }
      claudeResult = fresh
      Self.logClaudeLiveAttempt(fresh, now: now, nextAllowed: claudeNextAllowed)
    } else {
      // Not due yet: reuse a reset-bounded cache if one exists, and tell the menu
      // when the next live poll is expected rather than pretending this is live.
      let wait = claudeNextAllowed.timeIntervalSince(now)
      claudeResult = .failure(
        .claude,
        source: "deferred",
        error: "next live poll in \(ProviderResult.compactDuration(wait))"
      )
      Self.logger.info(
        "Claude live attempt skipped source=deferred next_allowed_in=\(max(0, wait), privacy: .public) cache_age=\(cacheAgeBeforePoll, privacy: .public)"
      )
    }

    let reconciledCodex = resultCache.reconcile(await codexResult, now: now)
    let reconciledClaude = resultCache.reconcile(claudeResult, now: now)
    let reconciledAntigravity = resultCache.reconcile(await antigravityResult, now: now)
    Self.logClaudeStatus(reconciledClaude, now: now)

    status = UsageStatus(
      generatedAt: now,
      results: [reconciledCodex, reconciledClaude, reconciledAntigravity]
    )
  }

  private static func logClaudeLiveAttempt(_ result: ProviderResult, now: Date, nextAllowed: Date) {
    let summary = ClaudeWindowLogSummary(result: result, now: now)
    logger.info(
      "Claude live attempt ok=\(result.ok, privacy: .public) source=\(result.source, privacy: .public) error=\(result.error ?? "none", privacy: .public) retry_after=\(result.retryAfterSeconds ?? -1, privacy: .public) next_allowed_in=\(max(0, nextAllowed.timeIntervalSince(now)), privacy: .public) windows=\(result.windows.count, privacy: .public) fast_used=\(summary.fastUsed, privacy: .public) fast_reset_in=\(summary.fastResetIn, privacy: .public) slow_used=\(summary.slowUsed, privacy: .public) slow_reset_in=\(summary.slowResetIn, privacy: .public)"
    )
  }

  private static func logClaudeStatus(_ result: ProviderResult, now: Date) {
    let summary = ClaudeWindowLogSummary(result: result, now: now)
    logger.info(
      "Claude status ok=\(result.ok, privacy: .public) source=\(result.source, privacy: .public) error=\(result.error ?? "none", privacy: .public) retry_after=\(result.retryAfterSeconds ?? -1, privacy: .public) cache_age=\(result.cacheAgeSeconds ?? -1, privacy: .public) windows=\(result.windows.count, privacy: .public) fast_used=\(summary.fastUsed, privacy: .public) fast_reset_in=\(summary.fastResetIn, privacy: .public) slow_used=\(summary.slowUsed, privacy: .public) slow_reset_in=\(summary.slowResetIn, privacy: .public)"
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
      let document = try JSONDecoder.glideslope.decode(PersistedUsageCache.self, from: data)
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
        result[provider] = entry.value
      }
    } catch {
      // Missing, corrupt, or old cache files are non-fatal. A future successful
      // provider response will atomically replace them.
      lastGood = [:]
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
  /// window's own reset boundary, while preserving the current error/auth state
  /// in the menu. This keeps availability separate from data freshness without
  /// pretending an old reading is live.
  mutating func reconcile(_ result: ProviderResult, now: Date) -> ProviderResult {
    if result.ok, !result.windows.isEmpty {
      // Reuse the latest successful response during deferred/transient cycles,
      // including scoped limits such as Fable. A later successful response that
      // omits a scoped limit naturally replaces the cache and clears the marker.
      lastGood[result.provider] = CachedUsageReading(
        windows: result.windows,
        capturedAt: now,
        sourceIdentity: result.provider == .antigravity ? antigravitySourceIdentity : nil
      )
      persist()
      return result
    }

    guard let cached = lastGood[result.provider], !cached.windows.isEmpty else {
      return result
    }

    let age = max(0, now.timeIntervalSince(cached.capturedAt))
    let validWindows = cached.windows
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
        cacheAgeSeconds: age,
        retryAfterSeconds: result.retryAfterSeconds
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
      retryAfterSeconds: result.retryAfterSeconds
    )
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
      let data = try JSONEncoder.glideslope.encode(document)
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
      .appending(path: "Glideslope", directoryHint: .isDirectory)
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
  let sourceIdentity: String?
}

private extension JSONEncoder {
  static var glideslope: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

private extension JSONDecoder {
  static var glideslope: JSONDecoder {
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
    let fast = result.windows.first { $0.provider == .claude && $0.speed == .fast }
    let slow = result.windows.first { $0.provider == .claude && $0.speed == .slow }
    fastUsed = fast?.usedPercent ?? -1
    fastResetIn = fast.map { max(0, $0.resetAt.timeIntervalSince(now)) } ?? -1
    slowUsed = slow?.usedPercent ?? -1
    slowResetIn = slow.map { max(0, $0.resetAt.timeIntervalSince(now)) } ?? -1
  }
}
