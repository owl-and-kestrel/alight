import Foundation
import OSLog

/// Projections of Fieldbook's reading of Alight's snapshots into what Alight
/// shows. Fieldbook's `normalizeAlightQuotaSnapshot` and `quotaWindowPace`
/// do the work; this only replays and substitutes.
@MainActor
enum QuotaProjection {
  private static let logger = Logger(subsystem: "com.owlandkestrel.alight", category: "projection")

  /// Fieldbook's reading of one outbox entry, as of the snapshot's own
  /// `writtenAt` (a replayed snapshot is not stale for its own time).
  static func reading(of entry: QuotaOutboxEntry, core: Result<CoreScript, Error> = CoreScript.shared) -> FieldbookAlightReading? {
    guard let writtenAt = entry.writtenAt else { return nil }
    do {
      let reading = try core.get().normalizeAlightQuotaSnapshot(entry.snapshot, readAt: writtenAt)
      if reading.status != "observed" {
        logger.error("Fieldbook did not read outbox entry \(entry.sequence, privacy: .public): \(reading.reasons.joined(separator: ","), privacy: .public)")
        return nil
      }
      return reading
    } catch {
      logger.error("Fieldbook reading unavailable: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  /// Records `entry` in `history`: each provider Fieldbook read as observed,
  /// at its capture time. A cached reading repeats an earlier capture and
  /// history ignores it.
  static func record(_ entry: QuotaOutboxEntry, into history: inout UsageHistory, core: Result<CoreScript, Error> = CoreScript.shared) {
    guard let reading = reading(of: entry, core: core) else { return }
    for provider in reading.providers.map(\.provider) {
      guard let usage = reading.usage(for: provider),
        let capturedAt = usage.observedAt.flatMap(FieldbookTime.date)
      else { continue }
      history.record(
        ProviderResult(
          provider: provider, ok: true, source: "live", error: nil, windows: usage.usageWindows(),
          observationIdentity: entry.identities[provider]
        ),
        capturedAt: capturedAt
      )
    }
  }

  /// History replayed from the outbox on top of `base` (the pre-Fieldbook
  /// history, if any); readings already in `base` are not repeated.
  static func history(base: UsageHistory, entries: [QuotaOutboxEntry], core: Result<CoreScript, Error> = CoreScript.shared) -> UsageHistory {
    var history = base
    for entry in entries { record(entry, into: &history, core: core) }
    return history
  }

  /// `results` with each provider Fieldbook read as observed showing
  /// Fieldbook's windows; status, errors and sign-in state stay Alight's.
  static func shown(_ results: [ProviderResult], reading: FieldbookAlightReading) -> [ProviderResult] {
    results.map { result in
      guard let usage = reading.usage(for: result.provider) else { return result }
      return result.replacingWindows(usage.usageWindows())
    }
  }

  /// `status` with every window's pace from Fieldbook's `quotaWindowPace`
  /// (linear curve, no reserve). Without the core, the clients' own pace stays.
  static func paced(_ status: UsageStatus, now: Date, core: Result<CoreScript, Error> = CoreScript.shared) -> UsageStatus {
    var paced = status
    do {
      let core = try core.get()
      paced.results = try status.results.map { result in
        guard !result.windows.isEmpty else { return result }
        let paces = try core.quotaWindowPace(result.windows, now: now)
        return result.replacingWindows(zip(result.windows, paces).map { window, pace in
          guard let pace else { return window }
          return UsageWindow(
            provider: window.provider, speed: window.speed, scope: window.scope, visualStyle: window.visualStyle,
            usedPercent: window.usedPercent, remainingPercent: window.remainingPercent,
            expectedRemainingPercent: pace.expectedRemainingRatio * 100, pressurePercent: pace.pressurePercent,
            resetAt: window.resetAt, limitWindowSeconds: window.limitWindowSeconds
          )
        })
      }
    } catch {
      logger.error("Fieldbook pace unavailable: \(String(describing: error), privacy: .public)")
    }
    return paced
  }
}

extension UsageHistory {
  /// The pre-Fieldbook history file, read once into memory (it is never
  /// written again) so its readings stay visible until they age out.
  static func legacy(at url: URL?, now: Date) -> UsageHistory {
    var history = UsageHistory(persistenceURL: nil, now: now)
    guard let url, FileManager.default.fileExists(atPath: url.path) else { return history }
    let saved = UsageHistory(persistenceURL: url, now: now)
    let captures = Dictionary(grouping: saved.observations) { "\($0.window.provider.rawValue)@\($0.capturedAt.timeIntervalSince1970)" }
      .values.compactMap { group in group.first.map { ($0.capturedAt, $0.window.provider, group) } }
      .sorted { ($0.0, $0.1.rawValue) < ($1.0, $1.1.rawValue) }
    for (capturedAt, provider, group) in captures {
      history.record(
        ProviderResult(provider: provider, ok: true, source: "live", error: nil, windows: group.map(\.window), observationIdentity: group.first?.identity),
        capturedAt: capturedAt
      )
    }
    if history.observations.isEmpty { try? FileManager.default.removeItem(at: url) }
    return history
  }

  static var legacyURL: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appending(path: "Alight", directoryHint: .isDirectory).appending(path: "usage-history.json")
  }
}

extension ProviderResult {
  func replacingWindows(_ windows: [UsageWindow]) -> ProviderResult {
    ProviderResult(
      provider: provider, ok: ok, source: source, error: error, windows: windows,
      needsAuth: needsAuth, cacheAgeSeconds: cacheAgeSeconds, observationIdentity: observationIdentity,
      quotaReport: quotaReport, accountRef: accountRef, failureCode: failureCode, capturedAt: capturedAt
    )
  }
}
