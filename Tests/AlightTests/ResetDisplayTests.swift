import Foundation
import Testing
@testable import Alight

@Suite("Reset display")
struct ResetDisplayTests {
  @Test("reset graduations divide weekly days and fast hours")
  func resetGraduations() {
    let weekly = GaugeIconRenderer.resetGraduationAngles(count: 7)
    let fast = GaugeIconRenderer.resetGraduationAngles(count: 5)

    #expect(weekly.count == 7)
    #expect(fast.count == 5)
    #expect(weekly.first == 90)
    #expect(fast.first == 90)
    #expect(abs(weekly[1] - (90 - 360 / 7)) < 0.0001)
    #expect(abs(fast[1] - 18) < 0.0001)
  }

  @Test("reset hand rotates clockwise and returns to midnight")
  func resetHandPhase() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let duration: TimeInterval = 1_000
    let checkpoints: [(remaining: TimeInterval, angle: CGFloat)] = [
      (1_200, 90),
      (1_000, 90),
      (750, 0),
      (500, -90),
      (250, -180),
      (0, -270),
      (-100, -270)
    ]

    for checkpoint in checkpoints {
      let window = makeWindow(
        provider: .codex,
        speed: .slow,
        usedPercent: 10,
        resetAt: now.addingTimeInterval(checkpoint.remaining),
        duration: duration,
        now: now
      )
      #expect(GaugeIconRenderer.resetAngle(for: window, now: now) == checkpoint.angle)
    }
  }

  @Test("reset clock includes only active broad limits")
  func resetClockIncludesOnlyActiveBroadLimits() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let codexWeekly = makeWindow(
      provider: .codex,
      speed: .slow,
      usedPercent: 20,
      resetAt: now.addingTimeInterval(6 * 24 * 3_600),
      duration: 7 * 24 * 3_600,
      now: now
    )
    let claudeWeekly = makeWindow(
      provider: .claude,
      speed: .slow,
      usedPercent: 30,
      resetAt: now.addingTimeInterval(5 * 24 * 3_600),
      duration: 7 * 24 * 3_600,
      now: now
    )
    let claudeFast = makeWindow(
      provider: .claude,
      speed: .fast,
      usedPercent: 40,
      resetAt: now.addingTimeInterval(2 * 3_600),
      duration: 5 * 3_600,
      now: now
    )
    let fable = makeWindow(
      provider: .claude,
      speed: .slow,
      usedPercent: 50,
      resetAt: now.addingTimeInterval(4 * 24 * 3_600),
      duration: 7 * 24 * 3_600,
      now: now,
      scope: .fable,
      visualStyle: .outerStar
    )
    let expired = makeWindow(
      provider: .codex,
      speed: .fast,
      usedPercent: 60,
      resetAt: now.addingTimeInterval(-60),
      duration: 5 * 3_600,
      now: now
    )
    let status = UsageStatus(generatedAt: now, results: [
      ProviderResult(
        provider: .codex,
        ok: true,
        source: "sample",
        error: nil,
        windows: [codexWeekly, expired]
      ),
      ProviderResult(
        provider: .claude,
        ok: true,
        source: "sample",
        error: nil,
        windows: [claudeWeekly, claudeFast, fable]
      )
    ])

    let windows = GaugeIconRenderer.resetDialWindows(status: status, now: now)

    #expect(Set(windows.map(\.id)) == ["codex_slow", "claude_slow", "claude_fast"])
    #expect(!windows.contains { $0.provider == .codex && $0.speed == .fast })
    #expect(!windows.contains { $0.scope != nil })
  }

  @Test("reset countdown keeps the useful secondary unit")
  func resetCountdownFormatting() {
    #expect(UsageWindow.compactResetCountdown(6 * 24 * 3_600 + 20 * 3_600) == "6d 20h")
    #expect(UsageWindow.compactResetCountdown(2 * 3_600 + 5 * 60) == "2h 5m")
    #expect(UsageWindow.compactResetCountdown(59 * 60) == "59m")
    #expect(UsageWindow.compactResetCountdown(0) == "now")
    #expect(UsageWindow.compactResetCountdown(-60) == "now")

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let window = makeWindow(
      provider: .codex,
      speed: .slow,
      usedPercent: 10,
      resetAt: now.addingTimeInterval(6 * 24 * 3_600 + 20 * 3_600),
      duration: 7 * 24 * 3_600,
      now: now
    )
    #expect(window.resetDescription(now: now).hasSuffix("(6d 20h)"))
  }

  @Test("tooltip appends the worst window reset countdown")
  func tooltipUsesWorstWindowReset() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let codexWeekly = makeWindow(
      provider: .codex,
      speed: .slow,
      usedPercent: 60,
      resetAt: now.addingTimeInterval(6 * 24 * 3_600 + 20 * 3_600),
      duration: 7 * 24 * 3_600,
      now: now
    )
    let claudeFast = makeWindow(
      provider: .claude,
      speed: .fast,
      usedPercent: 10,
      resetAt: now.addingTimeInterval(60 * 60),
      duration: 5 * 3_600,
      now: now
    )
    let status = UsageStatus(generatedAt: now, results: [
      ProviderResult(
        provider: .codex,
        ok: true,
        source: "cached",
        error: nil,
        windows: [codexWeekly],
        cacheAgeSeconds: 120
      ),
      ProviderResult(
        provider: .claude,
        ok: true,
        source: "live",
        error: nil,
        windows: [claudeFast]
      )
    ])

    #expect(status.worst?.id == "codex_slow")
    #expect(status.summary.contains("Codex Weekly"))
    #expect(status.summary.contains("(cached 2m)"))
    #expect(status.summary.hasSuffix("resets in 6d 20h"))
  }

  private func makeWindow(
    provider: Provider,
    speed: WindowSpeed,
    usedPercent: Double,
    resetAt: Date,
    duration: TimeInterval,
    now: Date,
    scope: UsageScope? = nil,
    visualStyle: UsageVisualStyle = .hand
  ) -> UsageWindow {
    PressureMath.window(
      provider: provider,
      speed: speed,
      usedPercent: usedPercent,
      resetAt: resetAt,
      limitWindowSeconds: duration,
      now: now,
      scope: scope,
      visualStyle: visualStyle
    )
  }
}
