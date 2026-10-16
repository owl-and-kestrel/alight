import Foundation
import Testing
@testable import Alight

@Suite("Dashboard cards")
struct DashboardTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("default cards show limits, with 5-hour and weekly charts and runway ready to switch on")
  func defaultLayout() {
    let layout = DashboardLayout.defaultLayout(order: [.claude, .codex, .antigravity])
    #expect(layout.cards.map(\.provider) == [.claude, .codex, .antigravity])
    let elements = layout.cards[0].elements
    #expect(elements.map(\.kind) == [.meters, .chart, .chart, .runway])
    #expect(elements.map(\.enabled) == [true, false, false, false])
    #expect(elements.map(\.windows.span) == [.all, .short, .long, .all])
    #expect(elements[1].range == .day)
    #expect(elements[2].range == .week)
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

  @Test("index moves clamp and keep every card")
  func moveByIndex() {
    var layout = DashboardLayout.defaultLayout(order: [.codex, .claude, .antigravity])
    layout.move(fromIndex: 0, toIndex: 2)
    #expect(layout.cards.map(\.provider) == [.claude, .antigravity, .codex])
    layout.move(fromIndex: 2, toIndex: -5)
    #expect(layout.cards.map(\.provider) == [.codex, .claude, .antigravity])
    layout.move(fromIndex: 7, toIndex: 0)
    #expect(layout.cards.count == 3)
  }

  @Test("a dragged card takes a slot once its leading edge passes that card's middle")
  func reorderTarget() {
    // Three cards 100, 200 and 100 tall, 10 apart: tops 0, 110, 320.
    let heights: [CGFloat] = [100, 200, 100]
    func target(_ from: Int, _ translation: CGFloat) -> Int {
      CardReorder.targetIndex(heights: heights, spacing: 10, from: from, translation: translation)
    }
    #expect(target(0, 0) == 0)
    // Card 0's bottom (100 + t) passes card 1's middle (210) after t = 110.
    #expect(target(0, 109) == 0)
    #expect(target(0, 111) == 1)
    // And card 2's middle (370) after t = 270.
    #expect(target(0, 271) == 2)
    #expect(target(0, 5000) == 2)
    // Card 2's top (320 + t) passes card 1's middle (210) going up after t = -110.
    #expect(target(2, -109) == 2)
    #expect(target(2, -111) == 1)
    #expect(target(2, -5000) == 0)
  }

  @Test("cards between the origin and the target step aside by the dragged card's height")
  func reorderShift() {
    let heights: [CGFloat] = [100, 200, 100]
    func shift(_ index: Int, from: Int, to: Int) -> CGFloat {
      CardReorder.shift(index: index, heights: heights, spacing: 10, from: from, target: to)
    }
    #expect(shift(1, from: 0, to: 2) == -110)
    #expect(shift(2, from: 0, to: 2) == -110)
    #expect(shift(2, from: 0, to: 1) == 0)
    #expect(shift(0, from: 2, to: 0) == 110)
    #expect(shift(1, from: 2, to: 1) == 110)
    #expect(shift(0, from: 2, to: 1) == 0)
    #expect(shift(0, from: 0, to: 2) == 0)
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
    var card = DashboardCard(provider: .codex, windowSettings: ["codex_slow": WindowSettings(label: "Week", menuBar: .pinned)])
    card.elements[1].enabled = true
    card.elements[1].curve = .steps
    card.elements[0].windows.hidden = ["codex_fast"]
    let layout = DashboardLayout(cards: [card], menuBarLimit: 3)
    let decoded = try JSONDecoder().decode(DashboardLayout.self, from: JSONEncoder().encode(layout))
    #expect(decoded == layout)

    let foreign = """
      {"cards":[{"provider":"claude","elements":[{"kind":"sparkles"},{"kind":"chart","range":"fortnight","curve":"steps"}]}]}
      """
    let tolerant = try JSONDecoder().decode(DashboardLayout.self, from: Data(foreign.utf8))
    let only = try #require(tolerant.cards.first?.elements)
    #expect(only.map(\.kind) == [.chart])
    #expect(only[0].range == .day)
    #expect(only[0].curve == .steps)
  }

  @Test("a card for a provider this build does not know is left out; the rest of the layout survives")
  func unknownProviderCard() throws {
    let saved = """
      {"cards":[{"provider":"codex"},{"provider":"someday-provider"},{"provider":"claude"}],"menuBarLimit":3}
      """
    let layout = try JSONDecoder().decode(DashboardLayout.self, from: Data(saved.utf8))
    #expect(layout.cards.map(\.provider) == [.codex, .claude])
    #expect(layout.menuBarLimit == 3)
  }

  @Test("the earlier card-wide layout migrates onto elements, splitting history into 5-hour and weekly charts")
  func migration() throws {
    let saved = """
      {"cards":[{"id":"6B4A3A9E-6E0C-4B7C-9D0B-2B8E0D5A1C11","provider":"claude",
        "hiddenWindowIDs":["claude_slow"],
        "elements":[{"kind":"meters","enabled":true},{"kind":"history","enabled":true},{"kind":"forecast","enabled":false}],
        "valueStyle":"used","showsPaceMarker":false,"showsCountdown":false,"historyRange":"threeDays","showsPaceGuide":false}],
       "menuBarLimit":4}
      """
    let card = try #require(try JSONDecoder().decode(DashboardLayout.self, from: Data(saved.utf8)).cards.first)
    #expect(card.id.uuidString == "6B4A3A9E-6E0C-4B7C-9D0B-2B8E0D5A1C11")
    #expect(card.elements.map(\.kind) == [.meters, .chart, .chart, .runway])
    #expect(card.elements.map(\.enabled) == [true, true, true, false])
    #expect(card.elements[1].windows.span == .short)
    #expect(card.elements[1].range == .threeDays)
    #expect(card.elements[2].windows.span == .long)
    #expect(card.elements[2].range == .week)
    #expect(card.elements[1].id != card.elements[2].id)
    #expect(card.elements.allSatisfy { $0.valueStyle == .used && !$0.showsPaceGuide && $0.windows.hidden == ["claude_slow"] })
    #expect(card.elements[0].reset == .hidden)
    #expect(!card.elements[0].showsPaceMarker)
  }

  @Test("cards order weekly, short, then scoped; elements filter by span and hidden limits")
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
    let all = card.windows(in: status)
    #expect(all.map(\.id) == ["claude_slow", "claude_fast", "claude_slow_model_fable"])
    // The default weekly chart holds Fable; the 5-hour chart does not.
    #expect(card.windows(all, for: card.elements[1]).map(\.id) == ["claude_fast"])
    #expect(card.windows(all, for: card.elements[2]).map(\.id) == ["claude_slow", "claude_slow_model_fable"])
    var meters = card.elements[0]
    meters.windows.hidden = ["claude_fast"]
    #expect(card.windows(all, for: meters).map(\.id) == ["claude_slow", "claude_slow_model_fable"])
  }

  @Test("moving an element steps over elements that draw nothing")
  func elementMovesSkipUndrawn() {
    // Codex reports only a weekly limit: the default 5-hour chart draws nothing.
    let weekly = [window(.codex, .slow, used: 20)]
    var card = DashboardCard(provider: .codex)
    for index in card.elements.indices { card.elements[index].enabled = true }
    #expect(card.elements.map { card.draws($0, windows: weekly) } == [true, false, true, true])
    #expect(card.hiddenReason(card.elements[1], windows: weekly) == "Nothing to show: no 5-hour limits on this card")
    let ids = card.elements.map(\.id)

    // The weekly chart moving up passes the empty 5-hour chart and lands above Limits.
    card.moveElement(at: 2, by: -1, windows: weekly)
    #expect(card.elements.map(\.id) == [ids[2], ids[0], ids[1], ids[3]])
    // Limits moving down passes the empty chart and lands below Runway.
    card.moveElement(at: 1, by: 1, windows: weekly)
    #expect(card.elements.map(\.id) == [ids[2], ids[1], ids[3], ids[0]])
    // At the end nothing moves.
    card.moveElement(at: 3, by: 1, windows: weekly)
    #expect(card.elements.map(\.id) == [ids[2], ids[1], ids[3], ids[0]])

    card.elements[0].enabled = false
    #expect(card.hiddenReason(card.elements[0], windows: weekly) == "Off")
  }

  @Test("a custom label replaces a limit's name on that card only")
  func labels() {
    let fable = window(.claude, .slow, used: 20, scope: .fable)
    var card = DashboardCard(provider: .claude)
    #expect(card.label(for: fable) == "Fable")
    card.windowSettings[fable.id] = WindowSettings(label: "  Fable week ")
    #expect(card.label(for: fable) == "Fable week")
    card.windowSettings[fable.id] = WindowSettings(label: "   ")
    #expect(card.label(for: fable) == "Fable")
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
