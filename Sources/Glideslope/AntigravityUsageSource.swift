import CryptoKit
import Foundation

/// The native Antigravity client uses the daily backend. The unprefixed Code
/// Assist backend can return a different Gemini balance for the same account.
enum AntigravityUsageSource {
  static let defaultURL = URL(
    string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
  )!

  static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    let raw = environment["GLIDESLOPE_ANTIGRAVITY_USAGE_URL"] ?? defaultURL.absoluteString
    return URL(string: raw) ?? defaultURL
  }

  /// Bind derived cache entries to the actual endpoint without persisting an
  /// override's query, embedded credentials, or other potentially private text.
  static func cacheIdentity(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
    let endpoint = url(environment: environment).absoluteString
    return SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
