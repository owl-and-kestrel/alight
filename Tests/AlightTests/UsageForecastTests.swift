import Foundation
import Testing
@testable import Alight

@Suite("Quota runway forecasts")
struct UsageForecastTests {
  @Test("observed rate produces percentage-only runway, reset and earlier horizons")
  func projections() throws {
    let history = UsageHistoryFixture.history(values: [70, 75, 80])
    let now = UsageHistoryFixture.start.addingTimeInterval(600)
    let window = try #require(history.observations.last?.window)
    let forecast = UsageForecast(window: window, identity: UsageHistoryFixture.identity, observations: history.observations, now: now)
    #expect(forecast.unavailable == nil)
    #expect(forecast.ratePointsPerHour == 60)
    #expect(forecast.coverageSeconds == 600)
    #expect(abs((forecast.sustainablePointsPerHour ?? 0) - 24) < 0.000001)
    #expect(forecast.timeToZero == now.addingTimeInterval(1200))
    let reset = try #require(forecast.projection(at: window.resetAt))
    #expect(reset.remainingPercent == 0)
    #expect(reset.quotaOverrunPoints == 30)
    let earlier = try #require(forecast.projection(at: now.addingTimeInterval(600)))
    #expect(earlier.remainingPercent == 10)
    #expect(earlier.quotaOverrunPoints == 0)
    #expect(forecast.projection(at: window.resetAt.addingTimeInterval(1)) == nil)
    #expect(forecast.projection(at: now.addingTimeInterval(-1)) == nil)
  }

  @Test("aged projections include time elapsed since the last observation")
  func elapsedSinceReading() throws {
    let history = UsageHistoryFixture.history(values: [70, 75, 80])
    let window = try #require(history.observations.last?.window)
    let forecast = UsageForecast(window: window, identity: UsageHistoryFixture.identity, observations: history.observations, now: UsageHistoryFixture.start.addingTimeInterval(900))
    #expect(forecast.timeToZero == UsageHistoryFixture.start.addingTimeInterval(1800))
    #expect(forecast.projection(at: UsageHistoryFixture.start.addingTimeInterval(900))?.remainingPercent == 15)
  }

  @Test("thin, zero, stale, expired and reversed-clock coverage refuses estimates")
  func unavailableCases() throws {
    let thin = UsageHistoryFixture.history(values: [10, 20])
    #expect(make(thin, now: UsageHistoryFixture.start.addingTimeInterval(300)).unavailable == .insufficientCoverage)
    let tooShort = UsageHistoryFixture.history(values: [10, 20, 30], step: 60)
    #expect(make(tooShort, now: UsageHistoryFixture.start.addingTimeInterval(120)).unavailable == .insufficientCoverage)
    let zero = UsageHistoryFixture.history(values: [10, 10, 10])
    #expect(make(zero, now: UsageHistoryFixture.start.addingTimeInterval(600)).unavailable == .noConsumption)
    let live = UsageHistoryFixture.history(values: [10, 20, 30])
    let stale = make(live, now: UsageHistoryFixture.start.addingTimeInterval(1501))
    #expect(stale.unavailable == .stale)
    #expect(stale.ratePointsPerHour == nil)
    #expect(stale.timeToZero == nil)
    #expect(make(live, now: UsageHistoryFixture.reset).unavailable == .expired)
    #expect(make(live, now: UsageHistoryFixture.start).unavailable == .clockChanged)
  }

  @Test("a decrease rebuilds coverage instead of extrapolating the older slope")
  func decreaseInvalidates() {
    let history = UsageHistoryFixture.history(values: [10, 20, 30, 15])
    let forecast = make(history, now: UsageHistoryFixture.start.addingTimeInterval(900))
    #expect(forecast.unavailable == .insufficientCoverage)
    #expect(forecast.readingCount == 1)
  }

  @Test("current account, source and window must agree with observed lineage")
  func changedCurrentIdentity() throws {
    let history = UsageHistoryFixture.history(values: [10, 20, 30])
    let window = try #require(history.observations.last?.window)
    let changed = UsageObservationIdentity(source: "fixture", accountPartition: "account-b", limitIdentity: "plan-a")
    let forecast = UsageForecast(window: window, identity: changed, observations: history.observations, now: UsageHistoryFixture.start.addingTimeInterval(600))
    #expect(forecast.unavailable == .windowChanged)
    let nilIdentity = UsageForecast(window: window, identity: nil, observations: history.observations, now: UsageHistoryFixture.start.addingTimeInterval(600))
    #expect(nilIdentity.unavailable == .accountUnknown)
    let changedWindow = UsageHistoryFixture.result(used: 30, duration: 6 * 3600).windows[0]
    #expect(UsageForecast(window: changedWindow, identity: UsageHistoryFixture.identity, observations: history.observations, now: UsageHistoryFixture.start.addingTimeInterval(600)).unavailable == .windowChanged)
  }

  @Test("a slow positive rate forecasts remaining quota but no exhaustion before reset")
  func slowConsumption() {
    let history = UsageHistoryFixture.history(values: [10, 10.5, 11])
    let forecast = make(history, now: UsageHistoryFixture.start.addingTimeInterval(600))
    #expect(forecast.ratePointsPerHour == 6)
    #expect(forecast.timeToZero == nil)
    #expect(forecast.projection(at: UsageHistoryFixture.reset)?.remainingPercent == 84)
  }

  private func make(_ history: UsageHistory, now: Date) -> UsageForecast {
    UsageForecast(window: history.observations.last!.window, identity: UsageHistoryFixture.identity, observations: history.observations, now: now)
  }
}
