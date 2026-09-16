import Foundation
import Testing
@testable import Alight

@Suite("Claude usage parser")
struct ClaudeUsageParserTests {
  @Test("partial broad-window responses are not authoritative")
  func partialBroadWindowResponseIsIncomplete() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payload: [String: Any] = [
      "five_hour": [
        "utilization": 25,
        "resets_at": "2027-01-15T09:00:00Z"
      ],
      "limits": [[
        "group": "weekly",
        "kind": "weekly_scoped",
        "is_active": true,
        "percent": 60,
        "scope": ["model": ["display_name": "Fable"]],
        "resets_at": "2027-01-20T09:00:00Z"
      ]]
    ]

    let windows = ClaudeUsageParser.windows(from: payload, now: now)

    #expect(windows.map(\.label).contains("Fable"))
    #expect(!ClaudeUsageParser.hasCompleteBroadWindows(windows))
  }

  @Test("both broad windows form a complete authoritative response")
  func completeBroadWindowResponseIsAuthoritative() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payload: [String: Any] = [
      "five_hour": [
        "utilization": 25,
        "resets_at": "2027-01-15T09:00:00Z"
      ],
      "seven_day": [
        "utilization": 40,
        "resets_at": "2027-01-20T09:00:00Z"
      ]
    ]

    let windows = ClaudeUsageParser.windows(from: payload, now: now)

    #expect(ClaudeUsageParser.hasCompleteBroadWindows(windows))
    #expect(windows.map(\.speed) == [.fast, .slow])
  }

  @Test("every active scoped limit surfaces and only Fable earns a star")
  func scopedLimitsBeyondFableSurfaceAsMenuRowsOnly() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payload: [String: Any] = [
      "five_hour": ["utilization": 10, "resets_at": "2027-01-15T09:00:00Z"],
      "seven_day": ["utilization": 30, "resets_at": "2027-01-20T09:00:00Z"],
      "limits": [
        [
          "group": "weekly",
          "kind": "weekly_scoped",
          "is_active": true,
          "percent": 78,
          "scope": ["model": ["display_name": "Fable"]],
          "resets_at": "2027-01-20T09:00:00Z"
        ],
        [
          "group": "weekly",
          "kind": "weekly_scoped",
          "is_active": true,
          "percent": 41,
          "scope": ["model": ["display_name": "Sonnet Pro"]],
          "resets_at": "2027-01-20T09:00:00Z"
        ],
        [
          "group": "weekly",
          "kind": "weekly_scoped",
          "is_active": false,
          "percent": 90,
          "scope": ["model": ["display_name": "Retired Model"]],
          "resets_at": "2027-01-20T09:00:00Z"
        ],
        ["group": "weekly", "kind": "weekly_all", "is_active": true, "percent": 44],
        ["group": "session", "kind": "session", "is_active": true, "percent": 5]
      ]
    ]

    let windows = ClaudeUsageParser.windows(from: payload, now: now)

    let sonnet = try #require(windows.first { $0.scope?.displayName == "Sonnet Pro" })
    #expect(sonnet.scope?.key == "sonnet-pro")
    #expect(sonnet.scope?.kind == "model")
    #expect(sonnet.visualStyle == .menuRow)
    #expect(sonnet.usedPercent == 41)
    #expect(sonnet.speed == .slow)
    #expect(sonnet.resetAt == Date(timeIntervalSince1970: 1_800_435_600))

    let fable = try #require(windows.first { $0.scope == .fable })
    #expect(fable.visualStyle == .outerStar)

    #expect(!windows.contains { $0.scope?.key == "retired-model" })
    #expect(ClaudeUsageParser.hasCompleteBroadWindows(windows))

    // Dropdown-only rows stay off the reset dial like every scoped window.
    let status = UsageStatus(generatedAt: now, results: [
      ProviderResult(provider: .claude, ok: true, source: "sample", error: nil, windows: windows)
    ])
    #expect(!GaugeIconRenderer.resetDialWindows(status: status, now: now).contains { $0.scope != nil })
  }

  @Test("duplicate scoped identities keep the first occurrence")
  func duplicateScopedLimitsKeepFirstOccurrence() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payload: [String: Any] = [
      "five_hour": ["utilization": 10, "resets_at": "2027-01-15T09:00:00Z"],
      "seven_day": ["utilization": 30, "resets_at": "2027-01-20T09:00:00Z"],
      "limits": [
        [
          "group": "weekly",
          "kind": "weekly_scoped",
          "is_active": true,
          "percent": 40,
          "scope": ["model": ["display_name": "Sonnet Pro"]]
        ],
        [
          "group": "weekly",
          "kind": "weekly_scoped",
          "is_active": true,
          "percent": 60,
          "scope": ["model": ["display_name": "Sonnet-Pro"]]
        ]
      ]
    ]

    let windows = ClaudeUsageParser.windows(from: payload, now: now).filter { $0.scope?.displayName != nil && $0.scope?.displayName != "Fable" }

    #expect(windows.count == 1)
    #expect(windows[0].usedPercent == 40)
  }

  @Test("scoped limits without a model identity fail closed")
  func scopedLimitWithoutModelIdentityIsSkipped() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payload: [String: Any] = [
      "five_hour": ["utilization": 10, "resets_at": "2027-01-15T09:00:00Z"],
      "seven_day": ["utilization": 30, "resets_at": "2027-01-20T09:00:00Z"],
      "limits": [
        ["group": "weekly", "kind": "weekly_scoped", "is_active": true, "percent": 50]
      ]
    ]

    let windows = ClaudeUsageParser.windows(from: payload, now: now)

    #expect(!windows.contains { $0.scope != nil })
    #expect(ClaudeUsageParser.hasCompleteBroadWindows(windows))
  }

  @Test("a scoped row cannot complete missing broad windows")
  func scopedRowCannotCompleteMissingBroadWindows() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payload: [String: Any] = [
      "five_hour": ["utilization": 25, "resets_at": "2027-01-15T09:00:00Z"],
      "limits": [
        [
          "group": "weekly",
          "kind": "weekly_scoped",
          "is_active": true,
          "percent": 41,
          "scope": ["model": ["display_name": "Sonnet Pro"]]
        ]
      ]
    ]

    let windows = ClaudeUsageParser.windows(from: payload, now: now)

    #expect(windows.contains { $0.visualStyle == .menuRow })
    #expect(!ClaudeUsageParser.hasCompleteBroadWindows(windows))
  }
}
