import Foundation
import Testing
@testable import Alight

@Suite("Antigravity account identity")
struct AntigravityAccountIdentityTests {
  private static func idToken(_ claims: [String: Any]) -> String {
    func segment(_ object: [String: Any]) -> String {
      (try! JSONSerialization.data(withJSONObject: object)).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    }
    return "\(segment(["alg": "RS256"])).\(segment(claims)).signature"
  }

  @Test("the id_token saved with the access token names the Google account")
  func subjectFromTokenFiles() throws {
    let token = Self.idToken(["iss": "https://accounts.google.com", "sub": "1098765432101234567890", "email": "a@example.com"])
    let shapeA = #"{"token":{"access_token":"ya29.a","expiry":"2099-01-01T00:00:00Z"},"auth_method":"oauth","id_token":"\#(token)"}"#
    let shapeB = #"{"access_token":"ya29.b","expiry_date":4070908800000,"id_token":"\#(token)"}"#
    #expect(AntigravityUsageClient.parseTokenJSON(shapeA)?.accountSubject == "1098765432101234567890")
    #expect(AntigravityUsageClient.parseTokenJSON(shapeB)?.accountSubject == "1098765432101234567890")
    #expect(AntigravityUsageClient.parseTokenJSON(#"{"access_token":"ya29.c"}"#)?.accountSubject == nil)
  }

  @Test("tokens that are not Google id_tokens with a subject give no identity")
  func refusals() {
    #expect(AntigravityUsageClient.googleSubject(fromIDToken: Self.idToken(["iss": "https://evil.example", "sub": "1"])) == nil)
    #expect(AntigravityUsageClient.googleSubject(fromIDToken: Self.idToken(["iss": "accounts.google.com"])) == nil)
    #expect(AntigravityUsageClient.googleSubject(fromIDToken: "not.a-jwt") == nil)
    #expect(AntigravityUsageClient.googleSubject(fromIDToken: "a.b.c") == nil)
  }

  @Test("the identity and Fieldbook account reference are digests, stable per account")
  func digests() throws {
    let source = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    let one = try #require(AntigravityUsageClient.observationIdentity(subject: "111", source: source))
    #expect(one == AntigravityUsageClient.observationIdentity(subject: "111", source: source))
    #expect(one != AntigravityUsageClient.observationIdentity(subject: "222", source: source))
    #expect(!one.accountPartition.contains("111"))
    #expect(one.accountPartition.count == 64)
    #expect(AntigravityUsageClient.observationIdentity(subject: nil, source: source) == nil)
    let ref = try #require(UsageAccountRef.digest(provider: .antigravity, organization: nil, identifier: "111", kind: .opaque))
    #expect(ref.count == 64 && ref != one.accountPartition)
  }

  @Test("identified readings join into one history line")
  func historyContinuity() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let identity = AntigravityUsageClient.observationIdentity(subject: "111", source: "s")
    var history = UsageHistory(persistenceURL: nil, now: start)
    for minute in 0..<3 {
      let at = start.addingTimeInterval(Double(minute) * 60)
      let window = PressureMath.window(provider: .antigravity, speed: .fast, usedPercent: Double(minute), resetAt: start.addingTimeInterval(9000), limitWindowSeconds: 18000, now: at)
      history.record(ProviderResult(provider: .antigravity, ok: true, source: "live", error: nil, windows: [window], observationIdentity: identity), capturedAt: at)
    }
    #expect(history.observations.count == 3)
    #expect(Set(history.observations.map(\.segment)).count == 1)
  }

  @Test("an unstarted window's drifting reset does not break the line; a real reset does")
  func unstartedWindowContinuity() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let identity = AntigravityUsageClient.observationIdentity(subject: "111", source: "s")
    var history = UsageHistory(persistenceURL: nil, now: start)
    func record(_ minute: Double, used: Double, resetAt: Date) {
      let at = start.addingTimeInterval(minute * 60)
      let window = PressureMath.window(provider: .antigravity, speed: .fast, usedPercent: used, resetAt: resetAt, limitWindowSeconds: 18000, now: at)
      history.record(ProviderResult(provider: .antigravity, ok: true, source: "live", error: nil, windows: [window], observationIdentity: identity), capturedAt: at)
    }
    // Unused: the reset is "now plus five hours" each time.
    record(0, used: 0, resetAt: start.addingTimeInterval(18000))
    record(1, used: 0, resetAt: start.addingTimeInterval(18060))
    // First use fixes the reset; the line continues from zero.
    record(2, used: 3, resetAt: start.addingTimeInterval(18120))
    record(3, used: 5, resetAt: start.addingTimeInterval(18120))
    #expect(Set(history.observations.map(\.segment)).count == 1)
    // A different reset after real use is a new window.
    record(4, used: 1, resetAt: start.addingTimeInterval(40000))
    #expect(Set(history.observations.map(\.segment)).count == 2)
  }

  @Test("the identity source is the endpoint fingerprint, never an override's credentials")
  func identitySourceCarriesNoSecrets() throws {
    let secret = "https://review-user:review-secret@example.invalid/quota?token=review-token"
    let source = AntigravityUsageClient.identitySource(environment: ["ALIGHT_ANTIGRAVITY_USAGE_URL": secret])
    for fragment in ["review-user", "review-secret", "review-token", "example.invalid"] {
      #expect(!source.contains(fragment))
    }
    #expect(source != AntigravityUsageClient.identitySource(environment: [:]))
    let identity = try #require(AntigravityUsageClient.observationIdentity(subject: "111", source: source))
    let line = String(decoding: try QuotaOutbox.encode(QuotaOutboxEntry(
      sequence: 1, identities: [.antigravity: identity], snapshot: Data("{}".utf8)
    )), as: UTF8.self)
    #expect(!line.contains("review-secret") && !line.contains("review-token"))
  }
}
