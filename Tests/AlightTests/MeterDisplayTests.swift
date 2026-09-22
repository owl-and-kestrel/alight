import AppKit
import Foundation
import Testing
@testable import Alight

@Suite("Meter display")
@MainActor
struct MeterDisplayTests {
  @Test("bar geometry centers bars vertically and orders top to bottom")
  func barGeometryLayout() {
    let empty = MeterIconRenderer.barGeometry(count: 0, totalHeight: 22, barWidth: 32)
    #expect(empty.isEmpty)

    let single = MeterIconRenderer.barGeometry(count: 1, totalHeight: 22, barWidth: 32)
    #expect(single.count == 1)
    #expect(single[0].height == 5.0)
    #expect(single[0].y == 8.5)

    let two = MeterIconRenderer.barGeometry(count: 2, totalHeight: 22, barWidth: 32)
    #expect(two.count == 2)
    #expect(two[0].height == 4.0)
    #expect(two[1].height == 4.0)
    // Top bar (index 0) has highest Y in AppKit
    #expect(two[0].y > two[1].y)
    #expect(two[0].y == 12.5)
    #expect(two[1].y == 5.5)

    let five = MeterIconRenderer.barGeometry(count: 5, totalHeight: 22, barWidth: 32)
    #expect(five.count == 5)
    for i in 0..<4 {
      #expect(five[i].y > five[i + 1].y)
    }
  }

  @Test("card layouts differentiate weekly and 5h cadence and order weekly on top")
  func cardLayoutsDifferentialCadence() {
    let now = Date()
    let codexSlow = makeWindow(provider: .codex, speed: .slow, usedPercent: 20, duration: 7 * 24 * 3600, now: now)
    let claudeFast = makeWindow(provider: .claude, speed: .fast, usedPercent: 40, duration: 5 * 3600, now: now)
    let claudeSlow = makeWindow(provider: .claude, speed: .slow, usedPercent: 30, duration: 7 * 24 * 3600, now: now)

    let status = UsageStatus(
      generatedAt: now,
      results: [
        ProviderResult(provider: .codex, ok: true, source: "test", error: nil, windows: [codexSlow]),
        ProviderResult(provider: .claude, ok: true, source: "test", error: nil, windows: [claudeSlow, claudeFast])
      ]
    )

    let groups = MeterIconRenderer.meterGroups(status: status)
    #expect(groups.count == 2)
    #expect(groups[0].provider == .codex)
    #expect(groups[1].provider == .claude)

    let style = AppSettings.meterStyle
    let iconSize = MeterIconRenderer.size(for: style)
    let cards = MeterIconRenderer.cardLayouts(
      groups: groups,
      style: style,
      totalHeight: 22.0,
      totalWidth: iconSize.width
    )
    #expect(cards.count == 2)

    // Codex has 1 slow bar
    let codexCard = cards[0]
    #expect(codexCard.bars.count == 1)
    #expect(codexCard.bars[0].isSlow)

    // Claude has 2 bars: weekly on top (thicker), 5h below (thinner)
    let claudeCard = cards[1]
    #expect(claudeCard.bars.count == 2)
    let claudeWeeklyBar = claudeCard.bars[0]
    let claudeFastBar = claudeCard.bars[1]

    #expect(claudeWeeklyBar.isSlow)
    #expect(!claudeFastBar.isSlow)
    // Weekly bar is thicker than 5h bar
    #expect(claudeWeeklyBar.rect.height > claudeFastBar.rect.height)

    // In AppKit (0,0 bottom-left), weekly bar is above 5h bar
    #expect(claudeWeeklyBar.rect.minY > claudeFastBar.rect.minY)

    // Cards are stacked: Codex card is above Claude card
    #expect(codexCard.cardRect.minY > claudeCard.cardRect.minY)
    // Plates share one height regardless of bar count; the single bar is centred.
    #expect(codexCard.cardRect.height == claudeCard.cardRect.height)
    #expect(abs(codexCard.bars[0].rect.midY - codexCard.cardRect.midY) < 0.01)
  }

  @Test("an active scoped limit becomes a third, thinnest bar and grows only its own plate")
  func scopedThirdBar() {
    let now = Date()
    let codexSlow = makeWindow(provider: .codex, speed: .slow, usedPercent: 20, duration: 7 * 24 * 3600, now: now)
    let claudeFast = makeWindow(provider: .claude, speed: .fast, usedPercent: 40, duration: 5 * 3600, now: now)
    let claudeSlow = makeWindow(provider: .claude, speed: .slow, usedPercent: 30, duration: 7 * 24 * 3600, now: now)
    let fable = makeWindow(provider: .claude, speed: .slow, usedPercent: 70, duration: 7 * 24 * 3600, now: now, scope: .fable, visualStyle: .outerStar)
    let status = UsageStatus(generatedAt: now, results: [
      ProviderResult(provider: .codex, ok: true, source: "test", error: nil, windows: [codexSlow]),
      ProviderResult(provider: .claude, ok: true, source: "test", error: nil, windows: [fable, claudeFast, claudeSlow])
    ])
    let groups = MeterIconRenderer.meterGroups(status: status)
    #expect(groups[1].windows.map(\.id) == [claudeSlow.id, fable.id, claudeFast.id])
    let style = AppSettings.meterStyle
    let cards = MeterIconRenderer.cardLayouts(groups: groups, style: style, totalWidth: MeterIconRenderer.size(for: style).width)
    #expect(cards[1].bars.count == 3)
    #expect(cards[1].bars[1].window.scope == .fable)
    #expect(cards[1].bars[1].rect.height < cards[1].bars[0].rect.height)
    #expect(cards[1].bars[0].rect.minY > cards[1].bars[1].rect.maxY)
    #expect(cards[1].bars[1].rect.minY > cards[1].bars[2].rect.maxY)
    #expect(cards[1].cardRect.height > cards[0].cardRect.height)
    #expect(cards[0].cardRect.minY > cards[1].cardRect.maxY)
  }

  @Test("meter windows exclude menuRow and sort provider with weekly before fast")
  func meterWindowsOrdering() {
    let now = Date()
    let codexSlow = makeWindow(provider: .codex, speed: .slow, usedPercent: 20, duration: 7 * 24 * 3600, now: now)
    let claudeFast = makeWindow(provider: .claude, speed: .fast, usedPercent: 40, duration: 5 * 3600, now: now)
    let claudeSlow = makeWindow(provider: .claude, speed: .slow, usedPercent: 30, duration: 7 * 24 * 3600, now: now)
    let antigravityFast = makeWindow(provider: .antigravity, speed: .fast, usedPercent: 50, duration: 5 * 3600, now: now)
    let scopedRow = makeWindow(
      provider: .claude,
      speed: .slow,
      usedPercent: 10,
      duration: 7 * 24 * 3600,
      now: now,
      scope: UsageScope(kind: "model", key: "other", displayName: "Other"),
      visualStyle: .menuRow
    )

    let status = UsageStatus(
      generatedAt: now,
      results: [
        ProviderResult(provider: .antigravity, ok: true, source: "test", error: nil, windows: [antigravityFast]),
        ProviderResult(provider: .claude, ok: true, source: "test", error: nil, windows: [claudeSlow, scopedRow, claudeFast]),
        ProviderResult(provider: .codex, ok: true, source: "test", error: nil, windows: [codexSlow])
      ]
    )

    let filtered = MeterIconRenderer.meterWindows(status: status)
    #expect(filtered.count == 4)
    #expect(!filtered.contains { $0.visualStyle == .menuRow })
    #expect(filtered[0].provider == .codex)
    // Claude: weekly before fast
    #expect(filtered[1].provider == .claude && filtered[1].speed == .slow)
    #expect(filtered[2].provider == .claude && filtered[2].speed == .fast)
    #expect(filtered[3].provider == .antigravity && filtered[3].speed == .fast)
  }

  @Test("level fraction reflects fill and empty modes correctly")
  func levelFractionMath() {
    let now = Date()
    let window = makeWindow(provider: .codex, speed: .slow, usedPercent: 35, duration: 7 * 24 * 3600, now: now)

    let fillFraction = MeterIconRenderer.levelFraction(for: window, fillMode: .fill)
    let emptyFraction = MeterIconRenderer.levelFraction(for: window, fillMode: .empty)

    #expect(abs(fillFraction - 0.35) < 0.0001)
    #expect(abs(emptyFraction - 0.65) < 0.0001)
  }

  @Test("fill rect computes correct dimensions for LTR and RTL")
  func fillRectMath() {
    let ltrHalf = MeterIconRenderer.fillRect(
      level: 0.5,
      barX: 2.0,
      barY: 5.0,
      barWidth: 30.0,
      barHeight: 4.0,
      direction: .leftToRight
    )
    #expect(ltrHalf.origin.x == 2.0)
    #expect(ltrHalf.width == 15.0)

    let rtlHalf = MeterIconRenderer.fillRect(
      level: 0.5,
      barX: 2.0,
      barY: 5.0,
      barWidth: 30.0,
      barHeight: 4.0,
      direction: .rightToLeft
    )
    #expect(rtlHalf.origin.x == 17.0)
    #expect(rtlHalf.width == 15.0)

    let rtlFull = MeterIconRenderer.fillRect(
      level: 1.0,
      barX: 2.0,
      barY: 5.0,
      barWidth: 30.0,
      barHeight: 4.0,
      direction: .rightToLeft
    )
    #expect(rtlFull.origin.x == 2.0)
    #expect(rtlFull.width == 30.0)
  }

  @Test("elapsed fraction tracks window progress from reset time")
  func elapsedFractionMath() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let duration: TimeInterval = 10_000

    let fresh = makeWindow(provider: .claude, speed: .fast, usedPercent: 0, resetAt: now.addingTimeInterval(duration), duration: duration, now: now)
    #expect(MeterIconRenderer.elapsedFraction(for: fresh, now: now) == 0.0)

    let midway = makeWindow(provider: .claude, speed: .fast, usedPercent: 0, resetAt: now.addingTimeInterval(duration / 2), duration: duration, now: now)
    #expect(abs(MeterIconRenderer.elapsedFraction(for: midway, now: now) - 0.5) < 0.0001)

    let expired = makeWindow(provider: .claude, speed: .fast, usedPercent: 0, resetAt: now.addingTimeInterval(-100), duration: duration, now: now)
    #expect(MeterIconRenderer.elapsedFraction(for: expired, now: now) == 1.0)
  }

  @Test("indicator position adapts to fill mode and direction")
  func indicatorPositionMath() {
    let barX: CGFloat = 2.0
    let barWidth: CGFloat = 30.0
    let elapsed: CGFloat = 0.25

    let fillLTR = MeterIconRenderer.indicatorPosition(
      elapsed: elapsed,
      barX: barX,
      barWidth: barWidth,
      fillMode: .fill,
      direction: .leftToRight
    )
    #expect(fillLTR == 9.5)

    let fillRTL = MeterIconRenderer.indicatorPosition(
      elapsed: elapsed,
      barX: barX,
      barWidth: barWidth,
      fillMode: .fill,
      direction: .rightToLeft
    )
    #expect(fillRTL == 24.5)

    let emptyLTR = MeterIconRenderer.indicatorPosition(
      elapsed: elapsed,
      barX: barX,
      barWidth: barWidth,
      fillMode: .empty,
      direction: .leftToRight
    )
    #expect(emptyLTR == 24.5)

    let emptyRTL = MeterIconRenderer.indicatorPosition(
      elapsed: elapsed,
      barX: barX,
      barWidth: barWidth,
      fillMode: .empty,
      direction: .rightToLeft
    )
    #expect(emptyRTL == 9.5)
  }

  @Test("row metrics keep three providers inside the menu bar height")
  func rowMetricsFit() {
    for count in 1...3 {
      let metrics = MeterIconRenderer.RowMetrics.forRowCount(count)
      // Worst case: every plate at base height plus one plate carrying a scoped bar.
      let total = CGFloat(count) * metrics.baseHeight + metrics.extraBarHeight + CGFloat(count - 1) * metrics.rowGap
      #expect(total <= MeterIconRenderer.standardHeight)
      #expect(metrics.rowGap >= 1.0 || count == 1)
      #expect(metrics.slowHeight > metrics.scopedHeight && metrics.slowHeight > metrics.fastHeight)
      #expect(metrics.slowHeight > metrics.fastHeight)
    }
  }

  @Test("swatch column adds width and is a centred square; bars-only drops it")
  func swatchAndSize() {
    func style(_ mode: MeterLabelMode) -> MeterIconStyle {
      MeterIconStyle(width: 36.0, fillMode: .fill, direction: .leftToRight, labelMode: mode,
                     codexColor: .cyan, claudeColor: .orange, antigravityColor: .purple)
    }
    let withSwatch = MeterIconRenderer.size(for: style(.swatch), height: 22)
    let barsOnly = MeterIconRenderer.size(for: style(.none), height: 22)
    #expect(withSwatch.width > barsOnly.width)

    let now = Date()
    let codexSlow = makeWindow(provider: .codex, speed: .slow, usedPercent: 20, duration: 7 * 24 * 3600, now: now)
    let status = UsageStatus(generatedAt: now, results: [
      ProviderResult(provider: .codex, ok: true, source: "test", error: nil, windows: [codexSlow])
    ])
    let groups = MeterIconRenderer.meterGroups(status: status)
    let card = MeterIconRenderer.cardLayouts(groups: groups, style: style(.swatch), totalHeight: 22, totalWidth: withSwatch.width)[0]
    #expect(card.badgeRect.width == card.badgeRect.height)
    #expect(abs(card.badgeRect.midY - card.cardRect.midY) < 0.01)
    #expect(card.badgeRect.maxX < card.tracksRect.minX)
    let bare = MeterIconRenderer.cardLayouts(groups: groups, style: style(.none), totalHeight: 22, totalWidth: barsOnly.width)[0]
    #expect(bare.badgeRect == .zero)
  }

  @Test("meter image renders for all style and label combinations")
  @MainActor
  func meterImageRendering() {
    let now = Date()
    let codexSlow = makeWindow(provider: .codex, speed: .slow, usedPercent: 30, duration: 7 * 24 * 3600, now: now)
    let claudeFast = makeWindow(provider: .claude, speed: .fast, usedPercent: 75, duration: 5 * 3600, now: now)
    let claudeSlow = makeWindow(provider: .claude, speed: .slow, usedPercent: 20, duration: 7 * 24 * 3600, now: now)
    let status = UsageStatus(
      generatedAt: now,
      results: [
        ProviderResult(provider: .codex, ok: true, source: "test", error: nil, windows: [codexSlow]),
        ProviderResult(provider: .claude, ok: true, source: "test", error: nil, windows: [claudeSlow, claudeFast])
      ]
    )

    for labelMode in MeterLabelMode.allCases {
      for fillMode in MeterFillMode.allCases {
        let style = MeterIconStyle(
          width: 36.0,
          fillMode: fillMode,
          direction: .leftToRight,
          labelMode: labelMode,
          codexColor: .cyan,
          claudeColor: .orange,
          antigravityColor: .purple
        )
        let img = MeterIconRenderer.image(status: status, scale: 2, style: style, now: now)
        let expected = MeterIconRenderer.size(for: style)
        #expect(img.size.width == expected.width * 2)
        #expect(img.size.height == expected.height * 2)
        #expect(expected.height >= 22 && expected.height <= MeterIconRenderer.maximumHeight)
      }
    }
  }

  @Test("settings persist display mode and meter configuration")
  func settingsPersistence() {
    AppSettings.resetIconStyle()
    #expect(AppSettings.displayMode == .gauge)
    #expect(AppSettings.meterFillMode == .fill)
    #expect(AppSettings.meterDirection == .leftToRight)
    #expect(AppSettings.meterLabelMode == .swatch)
    #expect(AppSettings.meterWidth == 36.0)

    AppSettings.displayMode = .meters
    AppSettings.meterFillMode = .empty
    AppSettings.meterDirection = .rightToLeft
    AppSettings.meterLabelMode = .none
    AppSettings.setValue(44.0, for: .meterWidth)

    #expect(AppSettings.displayMode == .meters)
    #expect(AppSettings.meterFillMode == .empty)
    #expect(AppSettings.meterDirection == .rightToLeft)
    #expect(AppSettings.meterLabelMode == .none)
    #expect(AppSettings.meterWidth == 44.0)

    // A stale text-label mode from an older build falls back to the default.
    UserDefaults.standard.set("monogram", forKey: "meterLabelMode")
    #expect(AppSettings.meterLabelMode == .swatch)

    AppSettings.resetIconStyle()
    #expect(AppSettings.displayMode == .gauge)
    #expect(AppSettings.meterFillMode == .fill)
    #expect(AppSettings.meterDirection == .leftToRight)
    #expect(AppSettings.meterLabelMode == .swatch)
    #expect(AppSettings.meterWidth == 36.0)
  }

  private func makeWindow(
    provider: Provider,
    speed: WindowSpeed,
    usedPercent: Double,
    resetAt: Date? = nil,
    duration: TimeInterval,
    now: Date,
    scope: UsageScope? = nil,
    visualStyle: UsageVisualStyle = .hand
  ) -> UsageWindow {
    let effectiveReset = resetAt ?? now.addingTimeInterval(duration * (1.0 - usedPercent / 100.0))
    return PressureMath.window(
      provider: provider,
      speed: speed,
      usedPercent: usedPercent,
      resetAt: effectiveReset,
      limitWindowSeconds: duration,
      now: now,
      scope: scope,
      visualStyle: visualStyle
    )
  }
}
