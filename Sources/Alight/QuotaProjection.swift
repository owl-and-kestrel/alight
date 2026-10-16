import Foundation
import OSLog

/// Projections of the Fieldbook outbox into what Alight shows.
enum QuotaProjection {
  private static let logger = Logger(subsystem: "com.owlandkestrel.alight", category: "projection")

  /// The chart and forecast history: every retained outbox entry, replayed
  /// through `UsageHistory`'s continuity rules.
  static func history(from entries: [QuotaOutboxEntry], now: Date) -> UsageHistory {
    var history = UsageHistory(persistenceURL: nil, now: now)
    for entry in entries { history.record(entry) }
    return history
  }

  /// A live result as its logged record reads back: the windows the app shows
  /// and the windows history holds are then the same values.
  static func result(_ result: ProviderResult, as observation: QuotaObservation, at capturedAt: Date) -> ProviderResult {
    result.replacingWindows(AlightQuotaProducer.windows(from: observation, now: capturedAt))
  }

  /// `status` with every window's pace from Fieldbook's `quotaWindowPace`
  /// (linear curve, no reserve). Without the core, the clients' own pace stays.
  @MainActor
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
  /// Records one outbox entry as a live reading at its observation time.
  mutating func record(_ entry: QuotaOutboxEntry) {
    guard let capturedAt = entry.observation.observedAt.flatMap(QuotaObservation.date) else { return }
    record(
      ProviderResult(
        provider: entry.provider, ok: true, source: "live", error: nil,
        windows: AlightQuotaProducer.windows(from: entry.observation, now: capturedAt),
        observationIdentity: entry.identity
      ),
      capturedAt: capturedAt
    )
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
