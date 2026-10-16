import Foundation
import Testing
@testable import Alight

@Suite("Dashboard cards")
struct DashboardTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("default layout follows the given provider order with limits only")
  func defaultLayout() {
    let layout = DashboardLayout.defaultLayout(order: [.claude, .codex, .antigravity])
    #expect(layout.cards.map(\.provider) == [.claude, .codex, .antigravity])
    #expect(layout.cards.allSatisfy { $0.visibleElements == [.meters] })
    #expect(layout.cards.allSatisfy { $0.elements.map(\.kind) == CardElement.allCases })
  }

  @Test("dragging onto a card takes its slot in either direction")
  func moveToPosition() {
    var layout = DashboardLayout.defaultLayout(order: [.codex, .claude, .antigravity])
    let ids = layout.cards.map(\.id)
    layout.move(ids[0], toPositionOf: ids[2])
    #expect(layout.cards.map(\.provider) == [.claude, .antigravity, .codex])
    layout.move(ids[0], toPositionOf: ids[1])
    #expect(layout.cards.map(\.provider) == [.codex, .claude, .antigravity])
    layout.move(ids[1], toPositionOf: ids[1])
    #expect(layout.cards.map(\.id) == ids)
  }

  @Test("any number of cards, including several per provider; provider order is first appearance")
  func addRemoveAndProviderOrder() {
    var layout = DashboardLayout(cards: [])
    layout.add(.antigravity)
    layout.add(.claude)
    layout.add(.antigravity)
    #expect(layout.cards.count == 3)
    #expect(layout.providerOrder == [.antigravity, .claude, .codex])
    layout.remove(layout.cards[0].id)
    #expect(layout.cards.map(\.provider) == [.claude, .antigravity])
  }

  @Test("layouts round-trip and tolerate unknown elements and missing fields")
  func decoding() throws {
    var card = DashboardCard(provider: .codex, hiddenWindowIDs: ["codex_fast"], valueStyle: .used, historyRange: .threeDays)
    card.setEnabled(.history, true)
    let layout = DashboardLayout(cards: [card])
    let decoded = try JSONDecoder().decode(DashboardLayout.self, from: JSONEncoder().encode(layout))
    #expect(decoded == layout)

    let foreign = """
      {"cards":[{"provider":"claude","elements":[{"kind":"sparkles","enabled":true},{"kind":"forecast","enabled":true}],"valueStyle":"someday"}]}
      """
    let tolerant = try JSONDecoder().decode(DashboardLayout.self, from: Data(foreign.utf8))
    let only = try #require(tolerant.cards.first)
    #expect(only.provider == .claude)
    #expect(only.elements.map(\.kind) == [.forecast, .meters, .history])
    #expect(only.visibleElements == [.forecast])
    #expect(only.valueStyle == .remaining)
    #expect(only.showsCountdown)
  }

  @Test("cards hide excluded windows and order weekly, short, then scoped")
  func cardWindows() {
    let windows = [
      window(.claude, .fast, used: 10),
      window(.claude, .slow, used: 20, scope: .fable),
      window(.claude, .slow, used: 30),
    ]
    let status = UsageStatus(generatedAt: now, results: [
      ProviderResult(provider: .claude, ok: true, source: "live", error: nil, windows: windows)
    ])
    let card = DashboardCard(provider: .claude)
    #expect(card.windows(in: status).map(\.id) == ["claude_slow", "claude_fast", "claude_slow_model_fable"])
    let hidden = DashboardCard(provider: .claude, hiddenWindowIDs: ["claude_fast"])
    #expect(hidden.windows(in: status).map(\.id) == ["claude_slow", "claude_slow_model_fable"])
  }

  @Test("layout store persists and survives a relaunch")
  @MainActor
  func layoutStorePersists() throws {
    let suite = "alight-dashboard-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = DashboardLayoutStore(defaults: defaults)
    var changes = 0
    store.onChange = { changes += 1 }
    store.layout.add(.codex)
    #expect(changes == 1)
    #expect(DashboardLayoutStore(defaults: defaults).layout == store.layout)
  }

  // MARK: History chart data

  @Test("segments become separate series, thinned to one reading per bucket")
  func chartSeries() {
    let identity = UsageObservationIdentity(source: "test", accountPartition: "a", limitIdentity: nil)
    var history = UsageHistory(persistenceURL: nil, now: now.addingTimeInterval(-7200))
    // Readings every minute for two hours; the 5h window resets halfway.
    for minute in 0...120 {
      let at = now.addingTimeInterval(TimeInterval(minute - 120) * 60)
      let reset = minute < 60 ? now.addingTimeInterval(-3600) : now.addingTimeInterval(4 * 3600)
      let used = Double(minute < 60 ? minute : minute - 60) / 2
      let result = ProviderResult(
        provider: .claude, ok: true, source: "live", error: nil,
        windows: [PressureMath.window(provider: .claude, speed: .fast, usedPercent: used, resetAt: reset, limitWindowSeconds: 5 * 3600, now: at)],
        observationIdentity: identity
      )
      history.record(result, capturedAt: at)
    }
    let current = window(.claude, .fast, used: 30, resetIn: 4 * 3600)

    let data = HistoryChartData.make(
      observations: history.observations, windows: [current], range: .sixHours, style: .used, now: now, bucketCount: 36
    )
    let series = Dictionary(grouping: data.points, by: \.series)
    #expect(series.count == 2)
    // 10-minute buckets over two hours, plus each segment's first reading.
    #expect(data.points.count <= 14 + 2)
    #expect(series.values.allSatisfy { points in zip(points, points.dropFirst()).allSatisfy { $0.value <= $1.value } })
    #expect(data.points.last?.value == 30)
    #expect(Set(data.guides.map(\.windowID)) == ["claude_fast"])
    #expect(data.guides.count == 2)

    let remaining = HistoryChartData.make(
      observations: history.observations, windows: [current], range: .sixHours, style: .remaining, now: now
    )
    #expect(remaining.points.last?.value == 70)
  }

  @Test("readings outside the range or for other windows are excluded")
  func chartFiltering() {
    let identity = UsageObservationIdentity(source: "test", accountPartition: "a", limitIdentity: nil)
    var history = UsageHistory(persistenceURL: nil, now: now.addingTimeInterval(-10 * 3600))
    for hour in [-9.0, -1.0] {
      let at = now.addingTimeInterval(hour * 3600)
      history.record(ProviderResult(
        provider: .codex, ok: true, source: "live", error: nil,
        windows: [
          PressureMath.window(provider: .codex, speed: .slow, usedPercent: 40, resetAt: now.addingTimeInterval(86400), limitWindowSeconds: 7 * 86400, now: at),
          PressureMath.window(provider: .codex, speed: .fast, usedPercent: 10, resetAt: now.addingTimeInterval(3600), limitWindowSeconds: 5 * 3600, now: at),
        ],
        observationIdentity: identity
      ), capturedAt: at)
    }
    let weekly = window(.codex, .slow, used: 40, resetIn: 86400)
    let data = HistoryChartData.make(observations: history.observations, windows: [weekly], range: .sixHours, style: .used, now: now)
    #expect(data.points.map(\.windowID) == ["codex_slow"])
    #expect(data.points.count == 1)
  }

  @Test("the pace guide runs from the window start to its reset, clipped to the range")
  func paceGuide() throws {
    let weekly = window(.codex, .slow, used: 40, resetIn: 3.5 * 86400)
    let domain = now.addingTimeInterval(-86400)...now
    let guide = try #require(HistoryChartData.paceGuide(window: weekly, key: "k", domain: domain, style: .used))
    #expect(guide.start.date == domain.lowerBound)
    #expect(guide.end.date == now)
    #expect(abs(guide.start.value - 2.5 / 7 * 100) < 0.0001)
    #expect(abs(guide.end.value - 3.5 / 7 * 100) < 0.0001)
  }

  private func window(_ provider: Provider, _ speed: WindowSpeed, used: Double, resetIn: TimeInterval = 3600, scope: UsageScope? = nil) -> UsageWindow {
    PressureMath.window(
      provider: provider, speed: speed, usedPercent: used, resetAt: now.addingTimeInterval(resetIn),
      limitWindowSeconds: speed == .slow ? 7 * 86400 : 5 * 3600, now: now, scope: scope
    )
  }
}
