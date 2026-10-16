import Foundation
import Testing
@testable import Alight

@Suite("Fieldbook quota reading and pace")
@MainActor
struct FieldbookQuotaTests {
  static let now = Date(timeIntervalSince1970: 1_800_000_000.123)
  static let producer = QuotaSnapshot.Producer(
    app: QuotaSnapshot.producerApp, version: "1.0.0", build: "1", sourceCommit: String(repeating: "ab", count: 20))

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

  // MARK: Fixtures (real client parsers, as the exporter's own tests use them)

  static func claudeResult(at now: Date = now) throws -> ProviderResult {
    let text = [
      "Current session: 16% used · resets Jan 15, 2027 at 2pm (UTC)",
      "Current week (all models): 40% used · resets Jan 18, 2027 at 9am (UTC)",
      "Current week (Fable): 0% used",
    ].joined(separator: "\n")
    let reading = try ClaudeUsageParser.reading(fromText: text, now: now)
    var result = ProviderResult(provider: .claude, ok: true, source: "live", error: nil, windows: reading.windows)
    result.quotaReport = reading.report
    result.accountRef = UsageAccountRef.digest(provider: .claude, organization: "org-1", identifier: "person@example.com", kind: .email)
    return result
  }

  static func codexResult(used: Double = 3, at now: Date = now) throws -> ProviderResult {
    let json = """
      {"rate_limit":{"primary_window":{"used_percent":\(used),"reset_at":1800300000,"limit_window_seconds":604800}}}
      """
    let payload = try JSONDecoder().decode(UsagePayload.self, from: Data(json.utf8))
    var result = ProviderResult(provider: .codex, ok: true, source: "live", error: nil, windows: CodexUsageParser.windows(from: payload, now: now))
    result.quotaReport = CodexUsageParser.quotaReport(from: payload)
    result.accountRef = UsageAccountRef.digest(provider: .codex, organization: nil, identifier: "acct-123", kind: .opaque)
    return result
  }

  static func antigravityResult(at now: Date = now) throws -> ProviderResult {
    let payload: [String: Any] = ["groups": [
      ["displayName": "Gemini Models", "buckets": [
        ["bucketId": "gemini-5h", "window": "5h", "resetTime": "2027-01-15T09:00:00Z", "remainingFraction": 0.75],
        ["bucketId": "gemini-weekly", "window": "weekly", "resetTime": "2027-01-20T09:00:00Z", "remainingFraction": 0.5],
      ]],
      ["displayName": "Claude and GPT models", "buckets": [
        ["bucketId": "3p-5h", "window": "5h", "resetTime": "2027-01-15T10:00:00Z", "remainingFraction": 0.7],
        ["bucketId": "3p-weekly", "window": "weekly", "resetTime": "2027-01-20T10:00:00Z", "remainingFraction": 0.6],
      ]],
    ]]
    var result = ProviderResult(provider: .antigravity, ok: true, source: "live", error: nil,
      windows: AntigravityUsageParser.windows(from: payload, now: now))
    result.quotaReport = AntigravityUsageParser.quotaReport(from: payload)
    return result
  }

  static func snapshot(_ results: [ProviderResult], at now: Date = now, sequence: Int = 0) throws -> Data {
    try QuotaSnapshotExporter.encode(QuotaSnapshotExporter.snapshot(
      results.map { .init(result: $0, attemptedAt: now, liveCapturedAt: now) },
      producer: producer, installId: "install-1", sequence: sequence, writtenAt: now, antigravityEndpointRef: nil
    ))
  }

  // MARK: Pace

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
            resetAt: Self.now.addingTimeInterval(duration * (1 - elapsed)), limitWindowSeconds: duration, now: Self.now
          ))
        }
      }
    }
    let paces = try core.quotaWindowPace(windows, now: Self.now)
    #expect(paces.count == windows.count)
    for (window, pace) in zip(windows, paces) {
      let pace = try #require(pace)
      #expect(abs(pace.pressurePercent - window.pressurePercent) < 0.006, "\(window)")
      #expect(abs(pace.expectedRemainingRatio * 100 - window.expectedRemainingPercent) < 0.006)
    }
  }

  @Test("paced status takes Fieldbook's pace, and keeps the clients' without the core")
  func pacedStatus() throws {
    let window = PressureMath.window(provider: .claude, speed: .fast, usedPercent: 80, resetAt: Self.now.addingTimeInterval(9000), limitWindowSeconds: 18000, now: Self.now)
    let status = UsageStatus(generatedAt: Self.now, results: [
      ProviderResult(provider: .claude, ok: true, source: "live", error: nil, windows: [window])
    ])
    let paced = try #require(QuotaProjection.paced(status, now: Self.now).windows.first)
    #expect(paced.pressurePercent == -30)
    #expect(paced.expectedRemainingPercent == 50)
    let fallback = QuotaProjection.paced(status, now: Self.now, core: .failure(CoreScript.Failure.bundleMissing))
    #expect(fallback.windows == status.windows)
  }

  @Test("timestamps are JavaScript's toISOString and round-trip exactly")
  func timestamps() throws {
    let core = try CoreScript.shared.get()
    let js = try #require(try core.evaluate("new Date(\(Self.now.timeIntervalSince1970 * 1000)).toISOString()")?.toString())
    #expect(FieldbookTime.timestamp(Self.now) == js)
    let parsed = try #require(FieldbookTime.date(js))
    #expect(FieldbookTime.timestamp(parsed) == js)
    #expect(FieldbookTime.date("2026-10-16T09:00:00Z") != nil)
  }

  // MARK: Reading Alight's snapshot

  @Test("Fieldbook reads an exported snapshot back as the clients' windows")
  func snapshotReadsBack() throws {
    let claude = try Self.claudeResult()
    let codex = try Self.codexResult()
    let antigravity = try Self.antigravityResult()
    let reading = try CoreScript.shared.get().normalizeAlightQuotaSnapshot(
      try Self.snapshot([claude, codex, antigravity]), readAt: Self.now
    )
    #expect(reading.status == "observed")
    #expect(reading.sequence == 0)

    for client in [claude, codex] {
      let usage = try #require(reading.usage(for: client.provider))
      #expect(usage.accountRef == client.accountRef)
      let projected = usage.usageWindows().sorted { $0.id < $1.id }
      let original = client.windows.sorted { $0.id < $1.id }
      #expect(projected.map(\.id) == original.map(\.id))
      #expect(projected.map(\.label) == original.map(\.label))
      #expect(projected.map(\.visualStyle) == original.map(\.visualStyle))
      for (back, window) in zip(projected, original) {
        #expect(abs(back.usedPercent - window.usedPercent) < 1e-9)
        #expect(abs(back.resetAt.timeIntervalSince(window.resetAt)) < 0.001, "\(back.id)")
        #expect(back.limitWindowSeconds == window.limitWindowSeconds)
      }
    }

    // Antigravity: Fieldbook keeps the Gemini group as the broad limits and
    // scopes the other group by its name.
    let usage = try #require(reading.usage(for: .antigravity))
    let windows = usage.usageWindows()
    #expect(Set(windows.map(\.id)) == [
      "antigravity_fast", "antigravity_slow",
      "antigravity_fast_group_claude_and_gpt_models", "antigravity_slow_group_claude_and_gpt_models",
    ])
    #expect(Set(windows.map(\.label)) == ["5h", "Weekly", "Claude and GPT models (5h)", "Claude and GPT models (Weekly)"])
    #expect(windows.filter { $0.scope != nil }.allSatisfy { $0.visualStyle == .menuRow })
    #expect(windows.first { $0.id == "antigravity_fast" }?.usedPercent == 25)
  }

  @Test("shown results keep Alight's status and take Fieldbook's windows")
  func shownResults() throws {
    let codex = try Self.codexResult(used: 7)
    let failed = ProviderResult.failure(.claude, source: "error", error: "signed out", needsAuth: true)
    let reading = try CoreScript.shared.get().normalizeAlightQuotaSnapshot(try Self.snapshot([codex, failed]), readAt: Self.now)
    let shown = QuotaProjection.shown([codex, failed], reading: reading)
    #expect(shown[0].windows.map(\.usedPercent) == [7])
    #expect(shown[1].needsAuth)
    #expect(shown[1].windows.isEmpty)
    #expect(reading.usage(for: .claude) == nil)
  }

  @Test("a stale or malformed snapshot is not read")
  func refusals() throws {
    let core = try CoreScript.shared.get()
    let snapshot = try Self.snapshot([try Self.codexResult()])
    let stale = try core.normalizeAlightQuotaSnapshot(snapshot, readAt: Self.now.addingTimeInterval(3600))
    #expect(stale.status == "unknown")
    #expect(stale.reasons == ["snapshot_stale"])
    let malformed = try core.normalizeAlightQuotaSnapshot(Data(#"{"schema":"ok.alight.quota-snapshot.v1"}"#.utf8), readAt: Self.now)
    #expect(malformed.status == "unknown")
  }
}
