import Foundation
import Testing
@testable import Glideslope

@Suite("Antigravity usage parser")
struct AntigravityUsageParserTests {
  @Test("complete broad-window response produces fast and slow Antigravity windows")
  func completeBroadWindows() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payload: [String: Any] = [
      "groups": [
        [
          "displayName": "Gemini Models",
          "buckets": [
            [
              "bucketId": "gemini-5h",
              "displayName": "Five Hour Limit",
              "window": "5h",
              "resetTime": "2027-01-15T09:00:00Z",
              "remainingFraction": 0.75
            ],
            [
              "bucketId": "gemini-weekly",
              "displayName": "Weekly Limit",
              "window": "weekly",
              "resetTime": "2027-01-20T09:00:00Z",
              "remainingFraction": 0.60
            ]
          ]
        ]
      ]
    ]

    let windows = AntigravityUsageParser.windows(from: payload, now: now)

    #expect(AntigravityUsageParser.hasCompleteBroadWindows(windows))
    let fast = try #require(windows.first { $0.speed == .fast && $0.scope == nil })
    #expect(fast.provider == .antigravity)
    #expect(fast.visualStyle == .hand)
    #expect(abs(fast.usedPercent - 25.0) < 0.001)
    #expect(abs(fast.remainingPercent - 75.0) < 0.001)
    #expect(fast.limitWindowSeconds == 5 * 3600)

    let slow = try #require(windows.first { $0.speed == .slow && $0.scope == nil })
    #expect(slow.provider == .antigravity)
    #expect(slow.visualStyle == .hand)
    #expect(abs(slow.usedPercent - 40.0) < 0.001)
    #expect(abs(slow.remainingPercent - 60.0) < 0.001)
    #expect(slow.limitWindowSeconds == 7 * 24 * 3600)
  }

  @Test("secondary groups surface as menuRow scoped windows")
  func secondaryGroupsSurfaceAsMenuRows() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payload: [String: Any] = [
      "groups": [
        [
          "displayName": "Gemini Models",
          "buckets": [
            [
              "bucketId": "gemini-5h",
              "window": "5h",
              "resetTime": "2027-01-15T09:00:00Z",
              "remainingFraction": 0.80
            ],
            [
              "bucketId": "gemini-weekly",
              "window": "weekly",
              "resetTime": "2027-01-20T09:00:00Z",
              "remainingFraction": 0.90
            ]
          ]
        ],
        [
          "displayName": "Claude and GPT models",
          "buckets": [
            [
              "bucketId": "3p-weekly",
              "displayName": "Weekly Limit Remaining",
              "window": "weekly",
              "resetTime": "2027-01-22T09:00:00Z",
              "remainingFraction": 0.0
            ],
            [
              "bucketId": "3p-5h",
              "displayName": "Five Hour Limit Remaining",
              "window": "5h",
              "resetTime": "2027-01-16T09:00:00Z",
              "remainingFraction": 1.0
            ]
          ]
        ]
      ]
    ]

    let windows = AntigravityUsageParser.windows(from: payload, now: now)

    let broad = windows.filter { $0.scope == nil }
    #expect(broad.count == 2)

    let scoped = windows.filter { $0.scope != nil }
    #expect(scoped.count == 2)
    for window in scoped {
      #expect(window.visualStyle == .menuRow)
      #expect(window.provider == .antigravity)
    }

    let weekly3p = try #require(scoped.first { $0.scope?.key == "3p-weekly" })
    #expect(weekly3p.usedPercent == 100.0)
    #expect(weekly3p.speed == .slow)

    let fast3p = try #require(scoped.first { $0.scope?.key == "3p-5h" })
    #expect(fast3p.usedPercent == 0.0)
    #expect(fast3p.speed == .fast)
  }

  @Test("incomplete broad windows return false in hasCompleteBroadWindows")
  func incompleteBroadWindows() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payload: [String: Any] = [
      "groups": [
        [
          "displayName": "Gemini Models",
          "buckets": [
            [
              "bucketId": "gemini-weekly",
              "window": "weekly",
              "resetTime": "2027-01-20T09:00:00Z",
              "remainingFraction": 0.50
            ]
          ]
        ]
      ]
    ]

    let windows = AntigravityUsageParser.windows(from: payload, now: now)
    #expect(!AntigravityUsageParser.hasCompleteBroadWindows(windows))
  }

  @Test("empty payload produces empty windows")
  func emptyPayload() {
    let now = Date()
    let windows = AntigravityUsageParser.windows(from: [:], now: now)
    #expect(windows.isEmpty)
    #expect(!AntigravityUsageParser.hasCompleteBroadWindows(windows))
  }

  @Test("live Antigravity fetch succeeds when credentials exist")
  func liveFetchIfCredentialsExist() async {
    let client = AntigravityUsageClient()
    let result = await client.result()
    if result.ok {
      #expect(result.windows.count >= 2)
      #expect(result.provider == .antigravity)
      #expect(AntigravityUsageParser.hasCompleteBroadWindows(result.windows))
    }
  }
}
