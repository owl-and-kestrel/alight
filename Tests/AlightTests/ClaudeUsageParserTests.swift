import Foundation
import Testing
@testable import Alight

@Suite("Claude /usage parser")
struct ClaudeUsageParserTests {
  /// 2026-10-08T14:30:00Z, when the Team-seat sample was captured (09:30 in
  /// America/Guayaquil, which is UTC-5 all year).
  private let sampleNow = Date(timeIntervalSince1970: 1_791_469_800)

  /// Shape of `claude -p /usage --output-format json` from a Team seat on
  /// Claude Code 2.1.286 (packet sample-usage-team-seat-20261008T1430Z),
  /// with the local usage breakdown shortened.
  static let teamSeatSample = #"""
  {"is_error":false,"duration_api_ms":0,"num_turns":0,"stop_reason":null,"session_id":"00000000-0000-4000-8000-000000000000","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0},"modelUsage":{},"permission_denials":[],"subtype":"success","result":"You are currently using your subscription to power your Claude Code usage\n\nCurrent session: 16% used · resets Oct 8 at 2pm (America/Guayaquil)\nCurrent week (Fable): 0% used · resets Oct 8 at 7pm (America/Guayaquil)\n\nWhat's contributing to your limits usage?\nApproximate, based on local sessions on this machine — does not include other devices or claude.ai. Behaviors are independent characteristics, not a breakdown.\n\nLast 24h · 4945 requests · 6 sessions\n  100% of your usage came from subagent-heavy sessions\n  Top subagents: workflow-subagent 37%, general-purpose 31%\n  Top MCP servers: terminal 1%","local_command":"usage","type":"result","duration_ms":1090,"uuid":"00000000-0000-4000-8000-000000000001","queued_turn_count":0,"result_index":0}
  """#

  static func commandOutput(
    result: String,
    numTurns: Int = 0,
    cost: Double = 0,
    subtype: String = "success",
    isError: Bool = false,
    localCommand: String? = "usage"
  ) -> Data {
    var object: [String: Any] = [
      "type": "result",
      "subtype": subtype,
      "is_error": isError,
      "num_turns": numTurns,
      "total_cost_usd": cost,
      "result": result,
    ]
    if let localCommand { object["local_command"] = localCommand }
    return try! JSONSerialization.data(withJSONObject: object)
  }

  private func date(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
  }

  @Test("Team seat sample: session-only plan with a Fable weekly limit is complete")
  func teamSeatSample() throws {
    let windows = try ClaudeUsageParser.windows(fromCommandOutput: Data(Self.teamSeatSample.utf8), now: sampleNow)

    #expect(windows.count == 2)
    let session = try #require(windows.first { $0.scope == nil })
    #expect(session.speed == .fast)
    #expect(session.usedPercent == 16)
    #expect(session.limitWindowSeconds == 5 * 3600)
    #expect(session.resetAt == date("2026-10-08T19:00:00Z"))
    #expect(session.label == "5h")

    let fable = try #require(windows.first { $0.scope == .fable })
    #expect(fable.speed == .slow)
    #expect(fable.visualStyle == .outerStar)
    #expect(fable.usedPercent == 0)
    #expect(fable.resetAt == date("2026-10-09T00:00:00Z"))
    #expect(!windows.contains { $0.scope == nil && $0.speed == .slow })
  }

  @Test("Pro/Max plans: all-models weekly is the broad slow window; other models are menu rows")
  func weeklyAllModelsAndScopedRows() throws {
    let text = """
      Current session: 42% used · resets Oct 8 at 2:30pm (America/Guayaquil)
      Current week (all models): 61.5% used · resets Oct 13 at 9am (America/Guayaquil)
      Current week (Fable): 78% used · resets Oct 13 at 9am (America/Guayaquil)
      Current week (Sonnet only): 12% used · resets Oct 13 at 9am (America/Guayaquil)
      """
    let windows = try ClaudeUsageParser.windows(fromText: text, now: sampleNow)

    #expect(windows.map(\.id) == ["claude_fast", "claude_slow", "claude_slow_model_fable", "claude_slow_model_sonnet"])
    #expect(windows[0].resetAt == date("2026-10-08T19:30:00Z"))
    #expect(windows[1].usedPercent == 61.5)
    #expect(windows[1].label == "Weekly")
    #expect(windows[1].resetAt == date("2026-10-13T14:00:00Z"))
    #expect(windows[2].visualStyle == .outerStar)
    #expect(windows[3].visualStyle == .menuRow)
    #expect(windows[3].label == "Sonnet")
  }

  @Test("reset variants: minutes, 24-hour, comma, time only, date only, relative")
  func resetVariants() throws {
    let zone = "(America/Guayaquil)"
    let cases: [(String, String)] = [
      ("Oct 8 at 2:05pm \(zone)", "2026-10-08T19:05:00Z"),
      ("Oct 8 at 14:05 \(zone)", "2026-10-08T19:05:00Z"),
      ("Oct 8, 2pm \(zone)", "2026-10-08T19:00:00Z"),
      ("October 9 at 12am \(zone)", "2026-10-09T05:00:00Z"),
      ("Oct 8 at 12pm \(zone)", "2026-10-08T17:00:00Z"),
      ("2pm \(zone)", "2026-10-08T19:00:00Z"),
      // 9am local already passed at 09:30, so a time-only reset is tomorrow.
      ("9am \(zone)", "2026-10-09T14:00:00Z"),
      ("Oct 10 \(zone)", "2026-10-10T05:00:00Z"),
      ("in 3h 12m", "2026-10-08T17:42:00Z"),
      ("in 45m", "2026-10-08T15:15:00Z"),
      ("in 1 hour 5 minutes", "2026-10-08T15:35:00Z"),
      ("Oct 8 at 2pm (UTC)", "2026-10-08T14:00:00Z"),
    ]
    for (clause, expected) in cases {
      #expect(ClaudeResetTime.parse(clause, now: sampleNow) == date(expected), "\(clause)")
    }
  }

  @Test("the reset year is inferred across the December to January boundary")
  func yearInference() {
    let lateDecember = date("2026-12-30T17:00:00Z")
    #expect(ClaudeResetTime.parse("Jan 2 at 9am (America/Guayaquil)", now: lateDecember)
      == date("2027-01-02T14:00:00Z"))
    let newYear = date("2027-01-01T01:00:00Z")
    #expect(ClaudeResetTime.parse("Dec 31 at 11pm (America/Guayaquil)", now: newYear)
      == date("2027-01-01T04:00:00Z"))
    #expect(ClaudeResetTime.parse("Jan 5 at 9am (America/Guayaquil)", now: newYear)
      == date("2027-01-05T14:00:00Z"))
  }

  @Test("unreadable reset phrases are rejected rather than guessed")
  func unreadableResets() {
    for clause in [
      "Oct 8 at 2pm (Not/AZone)",
      "Oct 8 at 14 (America/Guayaquil)",
      "Oct 8 at 13pm (America/Guayaquil)",
      "Octember 8 at 2pm (America/Guayaquil)",
      "Feb 30 at 2pm (America/Guayaquil)",
      "soon",
      "in a while",
      "",
    ] {
      #expect(ClaudeResetTime.parse(clause, now: sampleNow) == nil, "\(clause)")
    }
  }

  @Test("percent left is converted to percent used")
  func percentLeft() throws {
    let windows = try ClaudeUsageParser.windows(
      fromText: "Current session: 84% left · resets in 2h", now: sampleNow)
    #expect(windows.first?.usedPercent == 16)
  }

  @Test("an unused window without a reset starts fresh; a used one without a reset fails")
  func missingReset() throws {
    let fresh = try ClaudeUsageParser.windows(
      fromText: "Current session: 0% used\nCurrent week (all models): 0% used", now: sampleNow)
    #expect(fresh.count == 2)
    #expect(fresh[1].resetAt == sampleNow.addingTimeInterval(7 * 24 * 3600))

    #expect(throws: ClaudeUsageParser.Failure.unrecognizedLine("Current session")) {
      try ClaudeUsageParser.windows(fromText: "Current session: 5% used", now: sampleNow)
    }
  }

  @Test("a recognized line that cannot be read fails the whole reading")
  func unreadableRecognizedLine() {
    let text = """
      Current session: 16% used · resets Oct 8 at 2pm (America/Guayaquil)
      Current week (all models): lots used · resets Oct 13 at 9am (America/Guayaquil)
      """
    #expect(throws: ClaudeUsageParser.Failure.unrecognizedLine("Current week (all models)")) {
      try ClaudeUsageParser.windows(fromText: text, now: sampleNow)
    }
  }

  @Test("an implausible reset for the window length is rejected")
  func implausibleReset() {
    // A five-hour session cannot reset next week.
    #expect(throws: ClaudeUsageParser.Failure.unrecognizedLine("Current session")) {
      try ClaudeUsageParser.windows(
        fromText: "Current session: 16% used · resets Oct 15 at 2pm (America/Guayaquil)", now: sampleNow)
    }
  }

  @Test("unknown text, cost summaries, and sign-in prompts are explicit failures")
  func noLimits() {
    #expect(throws: ClaudeUsageParser.Failure.noLimits) {
      try ClaudeUsageParser.windows(fromText: "Usage data is temporarily unavailable.", now: sampleNow)
    }
    #expect(throws: ClaudeUsageParser.Failure.noLimits) {
      // Scoped limits alone are not a complete reading.
      try ClaudeUsageParser.windows(
        fromText: "Current week (Fable): 10% used · resets in 2d", now: sampleNow)
    }
    let costSummary = "Total cost:            $0.0000\nTotal duration (API):  0s\nUsage:                 0 input, 0 output"
    #expect(throws: ClaudeUsageParser.Failure.noPlanLimits) {
      try ClaudeUsageParser.windows(fromText: costSummary, now: sampleNow)
    }
    #expect(throws: ClaudeUsageParser.Failure.notSignedIn) {
      try ClaudeUsageParser.windows(fromText: "Not logged in · Please run /login", now: sampleNow)
    }
    #expect(throws: ClaudeUsageParser.Failure.notSignedIn) {
      try ClaudeUsageParser.windows(
        fromCommandOutput: Self.commandOutput(result: "Invalid API key · Please run /login", subtype: "error_during_execution", isError: true),
        now: sampleNow)
    }
  }

  @Test("a model turn is refused before its text is read")
  func modelTurnRefused() {
    let text = "Current session: 16% used · resets in 2h"
    #expect(throws: ClaudeUsageParser.Failure.modelTurn) {
      try ClaudeUsageParser.windows(fromCommandOutput: Self.commandOutput(result: text, numTurns: 1), now: sampleNow)
    }
    #expect(throws: ClaudeUsageParser.Failure.modelTurn) {
      try ClaudeUsageParser.windows(fromCommandOutput: Self.commandOutput(result: text, cost: 0.01), now: sampleNow)
    }
    let missingTurns = try! JSONSerialization.data(withJSONObject: [
      "type": "result", "subtype": "success", "local_command": "usage", "result": text,
    ])
    #expect(throws: ClaudeUsageParser.Failure.unexpectedShape) {
      try ClaudeUsageParser.windows(fromCommandOutput: missingTurns, now: sampleNow)
    }
  }

  @Test("non-JSON, foreign JSON, and non-usage commands are rejected")
  func malformedOutput() {
    #expect(throws: ClaudeUsageParser.Failure.notJSON) {
      try ClaudeUsageParser.windows(fromCommandOutput: Data("Current session: 16% used".utf8), now: sampleNow)
    }
    #expect(throws: ClaudeUsageParser.Failure.notJSON) {
      try ClaudeUsageParser.windows(fromCommandOutput: Data(), now: sampleNow)
    }
    #expect(throws: ClaudeUsageParser.Failure.unexpectedShape) {
      try ClaudeUsageParser.windows(fromCommandOutput: Data(#"{"type":"assistant"}"#.utf8), now: sampleNow)
    }
    #expect(throws: ClaudeUsageParser.Failure.notUsageCommand) {
      try ClaudeUsageParser.windows(
        fromCommandOutput: Self.commandOutput(result: "Current session: 16% used · resets in 2h", localCommand: nil),
        now: sampleNow)
    }
    #expect(throws: ClaudeUsageParser.Failure.commandFailed("Usage request failed")) {
      try ClaudeUsageParser.windows(
        fromCommandOutput: Self.commandOutput(result: "Usage request failed", subtype: "error_during_execution", isError: true),
        now: sampleNow)
    }
  }

  @Test("duplicate lines keep the first reading")
  func duplicates() throws {
    let text = """
      Current session: 16% used · resets in 2h
      Current session: 90% used · resets in 2h
      """
    let windows = try ClaudeUsageParser.windows(fromText: text, now: sampleNow)
    #expect(windows.count == 1)
    #expect(windows[0].usedPercent == 16)
  }
}
