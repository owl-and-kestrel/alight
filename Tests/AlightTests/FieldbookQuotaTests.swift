import Foundation
import Testing
@testable import Alight

@Suite("Fieldbook quota contract and pace")
@MainActor
struct FieldbookQuotaTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000.123)

  /// Mirrors Fieldbook's test/quota-pace.test.mjs: every pace vector, plus
  /// its lean spacing and expiring share, compared exactly in JavaScript.
  private static let paceRunner = """
    (function (goldenJSON) {
      const golden = JSON.parse(goldenJSON);
      const q = AlightCore.fieldbookQuota;
      const same = (a, b) => {
        if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return Object.is(a, b);
        if (Array.isArray(a) !== Array.isArray(b)) return false;
        const keys = Object.keys(a);
        return keys.length === Object.keys(b).length && keys.every((key) => same(a[key], b[key]));
      };
      const failures = [];
      for (const v of golden.pace) {
        const policy = golden.policies[v.policyName];
        const pace = q.quotaWindowPace(v.window, { policy, now: golden.now });
        const spacing = Object.keys(pace).length ? q.leanSpacingSeconds({ pressure: pace.pressure_ratio, pace, policy }) : null;
        if (!same(pace, v.pace) || !Object.is(spacing, v.leanSpacingSeconds) || !Object.is(q.windowExpiringShare(pace), v.expiringShare)) {
          failures.push(`${v.policyName} ${JSON.stringify(v.window)}`);
        }
      }
      return JSON.stringify({ count: golden.pace.length, failures: failures.slice(0, 5), failed: failures.length });
    })
    """

  @Test("Fieldbook's pace math matches Astra on every golden vector inside JavaScriptCore")
  func paceGoldenVectors() throws {
    let core = try CoreScript.shared.get()
    let url = try #require(Bundle.module.url(forResource: "astra-pace-golden", withExtension: "json", subdirectory: "Fixtures/fieldbook-quota"))
    let run = try #require(try core.evaluate(Self.paceRunner))
    let output = try #require(try core.call(run, [try String(contentsOf: url, encoding: .utf8)])?.toString())
    struct Summary: Decodable { let count: Int; let failures: [String]; let failed: Int }
    let summary = try JSONDecoder().decode(Summary.self, from: Data(output.utf8))
    #expect(summary.count >= 800)
    #expect(summary.failed == 0, "\(summary.failures)")
  }

  @Test("Fieldbook's linear pace is Alight's pace")
  func linearPaceParity() throws {
    let core = try CoreScript.shared.get()
    var windows: [UsageWindow] = []
    for used in stride(from: 0.0, through: 100, by: 12.5) {
      for elapsed in stride(from: 0.0, through: 1, by: 0.2) {
        for duration in [5 * 3600.0, 7 * 86400.0] {
          windows.append(PressureMath.window(
            provider: .codex, speed: .cadence(for: duration), usedPercent: used,
            resetAt: now.addingTimeInterval(duration * (1 - elapsed)), limitWindowSeconds: duration, now: now
          ))
        }
      }
    }
    let paces = try core.quotaWindowPace(windows, now: now)
    #expect(paces.count == windows.count)
    for (window, pace) in zip(windows, paces) {
      let pace = try #require(pace)
      #expect(abs(pace.pressurePercent - window.pressurePercent) < 0.006, "\(window)")
      #expect(abs(pace.expectedRemainingRatio * 100 - window.expectedRemainingPercent) < 0.006)
      #expect(pace.band == (window.band == .high ? "surplus" : window.band == .low ? "deficit" : "on_pace") || abs(abs(window.pressurePercent) - 5) < 0.01)
    }
  }

  @Test("paced status takes Fieldbook's pace, and keeps the clients' without the core")
  func pacedStatus() throws {
    let window = PressureMath.window(provider: .claude, speed: .fast, usedPercent: 80, resetAt: now.addingTimeInterval(9000), limitWindowSeconds: 18000, now: now)
    let status = UsageStatus(generatedAt: now, results: [
      ProviderResult(provider: .claude, ok: true, source: "live", error: nil, windows: [window])
    ])
    let paced = QuotaProjection.paced(status, now: now)
    let pacedWindow = try #require(paced.windows.first)
    #expect(pacedWindow.pressurePercent == -30)
    #expect(pacedWindow.expectedRemainingPercent == 50)
    #expect(pacedWindow.usedPercent == 80)

    let fallback = QuotaProjection.paced(status, now: now, core: .failure(CoreScript.Failure.bundleMissing))
    #expect(fallback.windows == status.windows)
  }

  @Test("timestamps are JavaScript's toISOString and parse back")
  func timestamps() throws {
    let core = try CoreScript.shared.get()
    let js = try #require(try core.evaluate("new Date(\(now.timeIntervalSince1970 * 1000)).toISOString()")?.toString())
    #expect(QuotaObservation.timestamp(now) == js)
    let parsed = try #require(QuotaObservation.date(js))
    #expect(abs(parsed.timeIntervalSince(now)) < 0.001)
    #expect(QuotaObservation.date("2026-10-16T09:00:00Z") != nil)
  }

  @Test("live readings become valid Fieldbook observations and read back as the same windows")
  func producerRoundTrip() throws {
    let windows = [
      PressureMath.window(provider: .claude, speed: .fast, usedPercent: 29, resetAt: now.addingTimeInterval(3600), limitWindowSeconds: 18000, now: now),
      PressureMath.window(provider: .claude, speed: .slow, usedPercent: 61.5, resetAt: now.addingTimeInterval(86400), limitWindowSeconds: 604800, now: now),
      PressureMath.window(provider: .claude, speed: .slow, usedPercent: 7, resetAt: now.addingTimeInterval(86400), limitWindowSeconds: 604800, now: now, scope: .fable, visualStyle: .outerStar),
      PressureMath.window(provider: .claude, speed: .slow, usedPercent: 12, resetAt: now.addingTimeInterval(86400), limitWindowSeconds: 604800, now: now,
        scope: UsageScope.modelScope(displayName: "Sonnet only"), visualStyle: .menuRow),
    ]
    let result = ProviderResult(provider: .claude, ok: true, source: "live", error: nil, windows: windows)
    let observation = try #require(AlightQuotaProducer.observation(for: result, capturedAt: now))
    #expect(observation.routeId == "cli:claude-code")
    #expect(observation.windows.map(\.windowId) == ["session", "week", "model:fable", "model:sonnet-only"])
    #expect(try CoreScript.shared.get().quotaObservationProblems(observation).isEmpty)

    let readBack = AlightQuotaProducer.windows(from: observation, now: now)
    #expect(readBack.map(\.id) == windows.map(\.id))
    #expect(readBack.map(\.visualStyle) == windows.map(\.visualStyle))
    #expect(readBack.map(\.label) == windows.map(\.label))
    for (back, original) in zip(readBack, windows) {
      #expect(abs(back.usedPercent - original.usedPercent) < 1e-9)
      #expect(abs(back.resetAt.timeIntervalSince(original.resetAt)) < 0.001)
      #expect(back.limitWindowSeconds == original.limitWindowSeconds)
    }
    // Reading the record back twice is stable: the record is the source of truth.
    let again = AlightQuotaProducer.windows(from: AlightQuotaProducer.observation(
      for: ProviderResult(provider: .claude, ok: true, source: "live", error: nil, windows: readBack), capturedAt: now
    )!, now: now)
    #expect(again == readBack)
  }

  @Test("only successful live readings are observed; Fieldbook rejects a malformed record")
  func observationScope() throws {
    let window = PressureMath.window(provider: .codex, speed: .slow, usedPercent: 10, resetAt: now.addingTimeInterval(3600), limitWindowSeconds: 604800, now: now)
    #expect(AlightQuotaProducer.observation(for: ProviderResult(provider: .codex, ok: true, source: "cached", error: nil, windows: [window]), capturedAt: now) == nil)
    #expect(AlightQuotaProducer.observation(for: .failure(.codex, source: "error", error: "x"), capturedAt: now) == nil)

    var observation = try #require(AlightQuotaProducer.observation(
      for: ProviderResult(provider: .codex, ok: true, source: "live", error: nil, windows: [window]), capturedAt: now
    ))
    observation.windows[0].usedFraction = 1.5
    observation.windows[0].resetsAt = "soon"
    let problems = try CoreScript.shared.get().quotaObservationProblems(observation)
    #expect(problems == ["windows[0].usedFraction", "windows[0].resetsAt"])
  }

  @Test("encoded observations carry explicit nulls, as Fieldbook's do")
  func explicitNulls() throws {
    let window = PressureMath.window(provider: .antigravity, speed: .fast, usedPercent: 10, resetAt: now.addingTimeInterval(3600), limitWindowSeconds: 18000, now: now)
    let observation = try #require(AlightQuotaProducer.observation(
      for: ProviderResult(provider: .antigravity, ok: true, source: "live", error: nil, windows: [window]), capturedAt: now
    ))
    let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(observation)) as? [String: Any])
    #expect(object["rawSha256"] is NSNull)
    #expect(object["contract"] as? String == "ok.fieldbook.quota-observation.v1")
    let first = try #require((object["windows"] as? [[String: Any]])?.first)
    #expect(first["rawSha256"] is NSNull)
  }
}
