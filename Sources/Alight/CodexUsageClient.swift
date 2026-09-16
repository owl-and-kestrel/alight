import Foundation

/// Reads local Codex auth and polls the ChatGPT usage endpoint Codex uses,
/// then maps the primary/secondary rate-limit windows onto Alight's
/// fast/slow pace windows. Never prints or caches the auth token.
struct CodexUsageClient: Sendable {
  private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

  func result(now: Date = Date()) async -> ProviderResult {
    do {
      let payload = try await fetchPayload()
      let windows = CodexUsageParser.windows(from: payload, now: now)
      return ProviderResult(provider: .codex, ok: !windows.isEmpty, source: "live", error: nil, windows: windows)
    } catch {
      let needsAuth: Bool
      if case UsageError.missingToken = error { needsAuth = true } else { needsAuth = false }
      return .failure(.codex, source: "error", error: CodexUsageClient.describe(error), needsAuth: needsAuth)
    }
  }

  private func fetchPayload() async throws -> UsagePayload {
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

    return try JSONDecoder().decode(UsagePayload.self, from: data)
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
