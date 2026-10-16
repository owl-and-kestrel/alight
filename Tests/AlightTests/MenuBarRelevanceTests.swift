import Foundation
import Testing
@testable import Alight

@Suite("Menu-bar relevance")
@MainActor
struct MenuBarRelevanceTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  /// Halfway through each window, so on-pace is 50% used.
  private func window(_ provider: Provider, _ speed: WindowSpeed, used: Double, scope: UsageScope? = nil, style: UsageVisualStyle = .hand) -> UsageWindow {
    let duration: TimeInterval = speed == .slow ? 7 * 86400 : 5 * 3600
    return PressureMath.window(
      provider: provider, speed: speed, usedPercent: used, resetAt: now.addingTimeInterval(duration / 2),
      limitWindowSeconds: duration, now: now, scope: scope, visualStyle: style
    )
  }

  private var status: UsageStatus {
    UsageStatus(generatedAt: now, results: [
      ProviderResult(provider: .codex, ok: true, source: "live", error: nil, windows: [window(.codex, .slow, used: 20)]),
      ProviderResult(provider: .claude, ok: true, source: "live", error: nil, windows: [
        window(.claude, .fast, used: 95),
        window(.claude, .slow, used: 70),
        window(.claude, .slow, used: 50, scope: .fable, style: .outerStar),
      ]),
      ProviderResult(provider: .antigravity, ok: true, source: "live", error: nil, windows: [
        window(.antigravity, .slow, used: 40),
        window(.antigravity, .fast, used: 99, scope: UsageScope.modelScope(displayName: "3P"), style: .menuRow),
      ]),
    ])
  }

  @Test("over-pace and scarce windows score higher; cached readings count for less")
  func salience() {
    let hot = window(.claude, .fast, used: 95)
    let onPace = window(.claude, .fast, used: 50)
    let cold = window(.claude, .fast, used: 10)
    #expect(MenuBarRelevance.salience(hot, result: nil) > MenuBarRelevance.salience(onPace, result: nil))
    #expect(MenuBarRelevance.salience(onPace, result: nil) > MenuBarRelevance.salience(cold, result: nil))
    #expect(MenuBarRelevance.salience(cold, result: nil) == 0)
    let cached = ProviderResult(provider: .claude, ok: true, source: "cached", error: nil, windows: [hot])
    #expect(MenuBarRelevance.salience(hot, result: cached) < MenuBarRelevance.salience(hot, result: nil))
  }

  @Test("Vane keeps the N most relevant windows; menu-row-only windows never compete")
  func selectsTopN() {
    var layout = DashboardLayout.defaultLayout()
    layout.menuBarLimit = 2
    let shown = MenuBarRelevance.select(status: status, layout: layout)
    #expect(Set(shown.windows.map(\.id)) == ["claude_fast", "claude_slow"])
    // Results stay, so the renderers keep provider state.
    #expect(shown.results.map(\.provider) == status.results.map(\.provider))

    layout.menuBarLimit = 6
    let all = MenuBarRelevance.select(status: status, layout: layout)
    #expect(all.windows.count == 5)
    #expect(!all.windows.contains { $0.visualStyle == .menuRow })
  }

  @Test("only windows on some card are candidates")
  func respectsCards() {
    var layout = DashboardLayout(cards: [DashboardCard(provider: .codex), DashboardCard(provider: .antigravity)], menuBarLimit: 6)
    #expect(Set(MenuBarRelevance.select(status: status, layout: layout).windows.map(\.id)) == ["codex_slow", "antigravity_slow"])
    layout.cards[1].hiddenWindowIDs = ["antigravity_slow"]
    #expect(MenuBarRelevance.select(status: status, layout: layout).windows.map(\.id) == ["codex_slow"])
  }

  @Test("without the bundled core, every candidate is shown rather than none")
  func fallback() {
    var layout = DashboardLayout.defaultLayout()
    layout.menuBarLimit = 1
    let shown = MenuBarRelevance.select(status: status, layout: layout, core: .failure(CoreScript.Failure.bundleMissing))
    #expect(shown.windows.count == 5)
  }

  @Test("menu-bar limit is clamped and decodes with a default")
  func limitCoding() throws {
    #expect(DashboardLayout(cards: [], menuBarLimit: 40).menuBarLimit == DashboardLayout.menuBarLimits.upperBound)
    let decoded = try JSONDecoder().decode(DashboardLayout.self, from: Data(#"{"cards":[]}"#.utf8))
    #expect(decoded.menuBarLimit == DashboardLayout.defaultMenuBarLimit)
  }
}
