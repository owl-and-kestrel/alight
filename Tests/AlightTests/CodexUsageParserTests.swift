import Foundation
import Testing
@testable import Alight

@Suite("Codex usage parser")
struct CodexUsageParserTests {
  @Test("weekly-only primary window follows its duration")
  func weeklyOnlyPrimaryWindowIsNotFiveHours() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payload = try decodePayload("""
      {
        "rate_limit": {
          "primary_window": {
            "used_percent": 12,
            "reset_at": 1800500000,
            "limit_window_seconds": 604800
          },
          "secondary_window": null
        }
      }
      """)

    let windows = CodexUsageParser.windows(from: payload, now: now)

    #expect(windows.count == 1)
    #expect(windows[0].speed == .slow)
    #expect(windows[0].label == "Weekly")
    #expect(windows[0].qualifiedLabel == "Codex Weekly")
    let status = UsageStatus(results: [
      ProviderResult(provider: .codex, ok: true, source: "live", error: nil, windows: windows)
    ])
    #expect(status.summary.hasPrefix("Codex Weekly "))
  }

  @Test("cadence follows duration rather than payload slot")
  func cadenceFollowsDurationRatherThanSlot() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payload = try decodePayload("""
      {
        "rate_limit": {
          "primary_window": {
            "used_percent": 20,
            "reset_at": 1800500000,
            "limit_window_seconds": 604800
          },
          "secondary_window": {
            "used_percent": 30,
            "reset_at": 1800010000,
            "limit_window_seconds": 18000
          }
        }
      }
      """)

    let windows = CodexUsageParser.windows(from: payload, now: now)

    #expect(windows.map(\.speed) == [.slow, .fast])
    #expect(windows.map(\.label) == ["Weekly", "5h"])
  }

  private func decodePayload(_ json: String) throws -> UsagePayload {
    try JSONDecoder().decode(UsagePayload.self, from: Data(json.utf8))
  }
}
