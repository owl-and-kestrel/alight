import Foundation
import CryptoKit

/// Reads local Codex auth and polls the ChatGPT usage endpoint Codex uses,
/// then maps the primary/secondary rate-limit windows onto Alight's
/// fast/slow pace windows. Never prints or caches the auth token.
struct CodexUsageClient: Sendable {
  private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

  func result(now: Date = Date()) async -> ProviderResult {
    do {
      let (payload, identity, accountRef) = try await fetchPayload()
      let windows = CodexUsageParser.windows(from: payload, now: now)
      var result = ProviderResult(provider: .codex, ok: !windows.isEmpty, source: "live", error: nil, windows: windows, observationIdentity: identity)
      result.quotaReport = CodexUsageParser.quotaReport(from: payload)
      result.accountRef = accountRef
      result.failureCode = windows.isEmpty ? .parseFailed : nil
      return result
    } catch {
      let needsAuth: Bool
      if case UsageError.missingToken = error { needsAuth = true } else { needsAuth = false }
      return .failure(
        .codex, source: "error", error: CodexUsageClient.describe(error), needsAuth: needsAuth,
        failureCode: CodexUsageClient.failureCode(error)
      )
    }
  }

  static func failureCode(_ error: Error) -> ProviderFailureCode {
    switch error {
    case UsageError.missingToken: .authRequired
    case is URLError: .network
    case is DecodingError: .parseFailed
    default: .unknown
    }
  }

  private func fetchPayload() async throws -> (UsagePayload, UsageObservationIdentity?, String?) {
    let auth = try readAuth()
    guard let token = auth.tokens?.accessToken, !token.isEmpty else {
      throw UsageError.missingToken
    }

    var request = URLRequest(url: usageURL)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Alight/0.3", forHTTPHeaderField: "User-Agent")
    if let accountId = auth.tokens?.accountId, !accountId.isEmpty {
      request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
    }

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw UsageError.fetchFailed
    }

    // Bind provenance to the exact auth snapshot sent above, never a later
    // credential read. Only a domain-separated digest reaches derived history.
    let identity = Self.observationIdentity(accountID: auth.tokens?.accountId, source: usageURL.absoluteString)
    let accountRef = UsageAccountRef.digest(
      provider: .codex, organization: nil, identifier: auth.tokens?.accountId, kind: .opaque)
    return (try JSONDecoder().decode(UsagePayload.self, from: data), identity, accountRef)
  }

  static func observationIdentity(accountID: String?, source: String) -> UsageObservationIdentity? {
    guard let accountID, !accountID.isEmpty else { return nil }
    let digest = SHA256.hash(data: Data("alight.usage-account.v1\u{0}codex\u{0}\(accountID)".utf8))
    return UsageObservationIdentity(source: source, accountPartition: digest.map { String(format: "%02x", $0) }.joined(), limitIdentity: nil)
  }

  private func readAuth() throws -> AuthFile {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:)) ?? home.appending(path: ".codex")
    let authURL = codexHome.appending(path: "auth.json")
    let data = try Data(contentsOf: authURL)
    return try JSONDecoder().decode(AuthFile.self, from: data)
  }

  static func describe(_ error: Error) -> String {
    switch error {
    case UsageError.missingToken: "no Codex auth (~/.codex/auth.json)"
    case UsageError.fetchFailed: "usage fetch failed"
    default: String(describing: error)
    }
  }
}

/// Codex's `primary_window` and `secondary_window` are transport slots, not
/// stable cadence names. Current plans may put a weekly-only limit in the
/// primary slot, so classify each window from its own reported duration.
enum CodexUsageParser {
  static func windows(from payload: UsagePayload, now: Date) -> [UsageWindow] {
    [payload.rateLimit.primaryWindow, payload.rateLimit.secondaryWindow]
      .compactMap { normalize($0, now: now) }
  }

  /// The same two slots, as reported: `used_percent` unclamped, the reported
  /// reset and window length. Nil when a length is not a whole positive
  /// number of seconds, so the export cannot name the window.
  static func quotaReport(from payload: UsagePayload) -> QuotaReport? {
    let slots: [(String, RateLimitWindow?)] = [
      ("primary_window", payload.rateLimit.primaryWindow),
      ("secondary_window", payload.rateLimit.secondaryWindow),
    ]
    var windows: [QuotaReportWindow] = []
    for (slot, window) in slots {
      guard let window else { continue }
      let seconds = window.limitWindowSeconds
      guard seconds.isFinite, seconds > 0, seconds <= 9_007_199_254_740_991, seconds.rounded() == seconds,
        window.resetAt.isFinite else {
        return nil
      }
      windows.append(QuotaReportWindow(
        windowSeconds: Int(seconds),
        windowSecondsSource: .provider,
        usedPercentRaw: window.usedPercent,
        usedPercentPrecision: .unverified,
        resetAt: Date(timeIntervalSince1970: window.resetAt),
        providerBucketId: slot,
        scope: nil
      ))
    }
    return windows.isEmpty ? nil : QuotaReport(groups: [QuotaReportGroup(providerGroup: nil, windows: windows)])
  }

  private static func normalize(_ window: RateLimitWindow?, now: Date) -> UsageWindow? {
    guard let window else {
      return nil
    }
    return PressureMath.window(
      provider: .codex,
      speed: .cadence(for: window.limitWindowSeconds),
      usedPercent: window.usedPercent,
      resetAt: Date(timeIntervalSince1970: window.resetAt),
      limitWindowSeconds: window.limitWindowSeconds,
      now: now
    )
  }
}

enum UsageError: Error {
  case missingToken
  case fetchFailed
}

struct UsagePayload: Decodable {
  let rateLimit: RateLimit

  enum CodingKeys: String, CodingKey {
    case rateLimit = "rate_limit"
  }
}

struct RateLimit: Decodable {
  let primaryWindow: RateLimitWindow?
  let secondaryWindow: RateLimitWindow?

  enum CodingKeys: String, CodingKey {
    case primaryWindow = "primary_window"
    case secondaryWindow = "secondary_window"
  }
}

struct RateLimitWindow: Decodable {
  let usedPercent: Double
  let resetAt: TimeInterval
  let limitWindowSeconds: TimeInterval

  enum CodingKeys: String, CodingKey {
    case usedPercent = "used_percent"
    case resetAt = "reset_at"
    case limitWindowSeconds = "limit_window_seconds"
  }
}

struct AuthFile: Decodable {
  let tokens: AuthTokens?
}

struct AuthTokens: Decodable {
  let accessToken: String?
  let accountId: String?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case accountId = "account_id"
  }
}
