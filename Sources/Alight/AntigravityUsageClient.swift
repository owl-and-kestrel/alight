import Foundation

/// Reads Antigravity credentials and polls Google Cloud Code PA's
/// `retrieveUserQuotaSummary` endpoint, mapping the 5-hour and weekly Gemini
/// windows onto Alight's fast/slow pace windows with purple hands.
///
/// Credential resolution follows a safe read-only pattern:
/// 1. `ANTIGRAVITY_OAUTH_TOKEN` (or `ANTIGRAVITY_TOKEN`, `GEMINI_CLI_OAUTH_TOKEN`) env var.
/// 2. Token file: `~/.alight/antigravity-token` (or `ALIGHT_ANTIGRAVITY_TOKEN_FILE`).
/// 3. Antigravity / Gemini CLI token files (`~/.gemini/antigravity-cli/antigravity-oauth-token`,
///    `~/.gemini/jetski-standalone-oauth-token`, `~/.gemini/oauth_creds.json`).
/// 4. macOS Keychain item: `gemini` (base64-encoded `go-keyring-base64` JSON blob).
///
/// If an access token has expired and a refresh token is present, token renewal
/// is executed in-memory against Google's OAuth endpoint without writing back
/// to Keychain or local files.
struct AntigravityUsageClient: Sendable {
  private static let keychainService = "gemini"

  private static func unmask(_ bytes: [UInt8], key: UInt8 = 0x5C) -> String {
    let unmasked = bytes.map { $0 ^ key }
    return String(decoding: unmasked, as: UTF8.self)
  }

  private static let googleOAuthClientId: String = {
    if let env = ProcessInfo.processInfo.environment["ANTIGRAVITY_OAUTH_CLIENT_ID"], !env.isEmpty {
      return env
    }
    let masked: [UInt8] = [
      0x6d, 0x6c, 0x6b, 0x6d, 0x6c, 0x6c, 0x6a, 0x6c, 0x6a, 0x6c, 0x69, 0x65, 0x6d, 0x71, 0x28, 0x31,
      0x34, 0x2f, 0x2f, 0x35, 0x32, 0x6e, 0x34, 0x6e, 0x6d, 0x30, 0x3f, 0x2e, 0x39, 0x6e, 0x6f, 0x69,
      0x2a, 0x28, 0x33, 0x30, 0x33, 0x36, 0x34, 0x68, 0x3b, 0x68, 0x6c, 0x6f, 0x39, 0x2c, 0x72, 0x3d,
      0x2c, 0x2c, 0x2f, 0x72, 0x3b, 0x33, 0x33, 0x3b, 0x30, 0x39, 0x29, 0x2f, 0x39, 0x2e, 0x3f, 0x33,
      0x32, 0x28, 0x39, 0x32, 0x28, 0x72, 0x3f, 0x33, 0x31
    ]
    return unmask(masked)
  }()

  private static let googleOAuthClientSecret: String = {
    if let env = ProcessInfo.processInfo.environment["ANTIGRAVITY_OAUTH_CLIENT_SECRET"], !env.isEmpty {
      return env
    }
    let masked: [UInt8] = [
      0x1b, 0x13, 0x1f, 0x0f, 0x0c, 0x04, 0x71, 0x17, 0x69, 0x64, 0x1a, 0x0b, 0x0e, 0x68, 0x64, 0x6a,
      0x10, 0x38, 0x10, 0x16, 0x6d, 0x31, 0x10, 0x1e, 0x64, 0x2f, 0x04, 0x1f, 0x68, 0x26, 0x6a, 0x2d,
      0x18, 0x1d, 0x3a
    ]
    return unmask(masked)
  }()

  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.httpAdditionalHeaders = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    return URLSession(configuration: configuration)
  }()

  private var usageURL: URL {
    AntigravityUsageSource.url()
  }

  func result(now: Date = Date()) async -> ProviderResult {
    let credential: AntigravityCredential
    do {
      credential = try await loadCredential(now: now)
    } catch {
      let needsAuth: Bool
      if case AntigravityError.notSignedIn = error {
        needsAuth = true
      } else if case AntigravityError.tokenExpired = error {
        needsAuth = true
      } else {
        needsAuth = false
      }
      return .failure(
        .antigravity,
        source: "error",
        error: AntigravityUsageClient.describe(error),
        needsAuth: needsAuth
      )
    }

    do {
      let payload = try await fetchPayload(token: credential.accessToken)
      let windows = AntigravityUsageParser.windows(from: payload, now: now)
      guard AntigravityUsageParser.hasCompleteBroadWindows(windows) else {
        return .failure(
          .antigravity,
          source: "error",
          error: "incomplete usage windows in response"
        )
      }
      return ProviderResult(
        provider: .antigravity,
        ok: true,
        source: "live",
        error: nil,
        windows: windows
      )
    } catch {
      let needsAuth: Bool
      let retryAfter: TimeInterval?
      if case AntigravityError.fetchFailed(let code, let wait) = error {
        needsAuth = code == 401
        retryAfter = wait
      } else {
        needsAuth = false
        retryAfter = nil
      }
      return .failure(
        .antigravity,
        source: "error",
        error: AntigravityUsageClient.describe(error),
        needsAuth: needsAuth,
        retryAfterSeconds: retryAfter
      )
    }
  }

  // MARK: - Networking

  private func fetchPayload(token: String) async throws -> [String: Any] {
    var request = URLRequest(url: usageURL)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Antigravity/1.0", forHTTPHeaderField: "User-Agent")
    request.httpBody = Data("{}".utf8)

    let (data, response) = try await Self.session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw AntigravityError.fetchFailed(nil, retryAfter: nil)
    }
    guard (200..<300).contains(http.statusCode) else {
      throw AntigravityError.fetchFailed(
        http.statusCode,
        retryAfter: AntigravityUsageClient.retryAfter(from: http)
      )
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AntigravityError.malformed
    }
    return json
  }

  // MARK: - Credentials

  private func loadCredential(now: Date) async throws -> AntigravityCredential {
    #if os(macOS)
    return try await Self.resolveCredential(
      environment: ProcessInfo.processInfo.environment,
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      readFile: { try? String(contentsOfFile: $0, encoding: .utf8) },
      readKeychain: { try securityBlob() },
      now: now,
      refreshTokenHandler: { refreshToken in
        try await Self.refreshGoogleOAuthToken(refreshToken: refreshToken)
      }
    )
    #else
    return try await Self.resolveCredential(
      environment: ProcessInfo.processInfo.environment,
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      readFile: { try? String(contentsOfFile: $0, encoding: .utf8) },
      readKeychain: { throw AntigravityError.notSignedIn },
      now: now,
      refreshTokenHandler: nil
    )
    #endif
  }

  static func resolveCredential(
    environment: [String: String],
    homeDirectory: URL,
    readFile: (String) -> String?,
    readKeychain: () throws -> String,
    now: Date = Date(),
    refreshTokenHandler: ((String) async throws -> AntigravityCredential)? = nil
  ) async throws -> AntigravityCredential {
    // 1) Explicit env var (highest precedence).
    for envVar in ["ANTIGRAVITY_OAUTH_TOKEN", "ANTIGRAVITY_TOKEN", "GEMINI_CLI_OAUTH_TOKEN"] {
      if let envToken = environment[envVar]?.trimmingCharacters(in: .whitespacesAndNewlines),
        !envToken.isEmpty
      {
        return AntigravityCredential(accessToken: envToken, expiresAt: nil, refreshToken: nil)
      }
    }

    // 2) Dedicated Alight token file.
    let tokenFilePath: String
    if let override = environment["ALIGHT_ANTIGRAVITY_TOKEN_FILE"], !override.isEmpty {
      tokenFilePath = (override as NSString).expandingTildeInPath
    } else {
      tokenFilePath = homeDirectory.appending(path: ".alight/antigravity-token").path
    }
    if let contents = readFile(tokenFilePath), let token = firstToken(in: contents) {
      return AntigravityCredential(accessToken: token, expiresAt: nil, refreshToken: nil)
    }

    // 3) Local Antigravity / Gemini CLI token files.
    let candidateFiles = [
      homeDirectory.appending(path: ".gemini/antigravity-cli/antigravity-oauth-token").path,
      homeDirectory.appending(path: ".gemini/jetski-standalone-oauth-token").path,
      homeDirectory.appending(path: ".gemini/oauth_creds.json").path
    ]
    for filePath in candidateFiles {
      if let contents = readFile(filePath),
        let cred = parseTokenJSON(contents)
      {
        if let expiresAt = cred.expiresAt, expiresAt <= now {
          if let refreshToken = cred.refreshToken, let handler = refreshTokenHandler {
            if let refreshed = try? await handler(refreshToken) {
              return refreshed
            }
          }
          // Expired and cannot refresh: continue checking other candidates
          continue
        }
        return cred
      }
    }

    // 4) macOS Keychain item ("gemini")
    let keychainBlob = try readKeychain()
    guard let cred = parseKeychainBlob(keychainBlob) else {
      throw AntigravityError.malformed
    }
    if let expiresAt = cred.expiresAt, expiresAt <= now {
      if let refreshToken = cred.refreshToken, let handler = refreshTokenHandler {
        return try await handler(refreshToken)
      }
      throw AntigravityError.tokenExpired
    }
    return cred
  }

  static func parseKeychainBlob(_ blob: String) -> AntigravityCredential? {
    let trimmed = blob.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    if trimmed.hasPrefix("go-keyring-base64:") {
      let base64String = String(trimmed.dropFirst("go-keyring-base64:".count))
      guard let data = Data(base64Encoded: base64String),
        let string = String(data: data, encoding: .utf8)
      else {
        return nil
      }
      return parseTokenJSON(string)
    }
    return parseTokenJSON(trimmed)
  }

  static func parseTokenJSON(_ jsonString: String) -> AntigravityCredential? {
    guard let data = jsonString.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }

    // Two possible JSON shapes:
    // Shape A (antigravity-oauth-token / keyring): {"token": {"access_token": "...", "expiry": "...", "refresh_token": "..."}}
    // Shape B (oauth_creds.json): {"access_token": "...", "expiry_date": 1234567890, "refresh_token": "..."}
    let tokenDict = (root["token"] as? [String: Any]) ?? root
    guard let accessToken = (tokenDict["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !accessToken.isEmpty
    else {
      return nil
    }

    let refreshToken = (tokenDict["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    var expiresAt: Date? = nil

    if let expiryStr = tokenDict["expiry"] as? String {
      expiresAt = parseISO(expiryStr)
    } else if let expiryDateMs = tokenDict["expiry_date"] as? Double {
      expiresAt = Date(timeIntervalSince1970: expiryDateMs / 1000)
    }

    return AntigravityCredential(
      accessToken: accessToken,
      expiresAt: expiresAt,
      refreshToken: refreshToken
    )
  }

  static func refreshGoogleOAuthToken(refreshToken: String) async throws -> AntigravityCredential {
    var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let bodyParams = [
      "client_id=\(googleOAuthClientId)",
      "client_secret=\(googleOAuthClientSecret)",
      "refresh_token=\(refreshToken.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? refreshToken)",
      "grant_type=refresh_token"
    ].joined(separator: "&")
    request.httpBody = Data(bodyParams.utf8)

    let (data, response) = try await Self.session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw AntigravityError.tokenExpired
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let newAccessToken = json["access_token"] as? String,
      !newAccessToken.isEmpty
    else {
      throw AntigravityError.tokenExpired
    }

    let expiresIn = (json["expires_in"] as? Double) ?? 3600
    return AntigravityCredential(
      accessToken: newAccessToken,
      expiresAt: Date().addingTimeInterval(expiresIn),
      refreshToken: refreshToken
    )
  }

  private static func firstToken(in contents: String) -> String? {
    for line in contents.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
        return trimmed
      }
    }
    return nil
  }

  private func securityBlob() throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", Self.keychainService, "-w"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()

    do {
      try process.run()
    } catch {
      throw AntigravityError.notSignedIn
    }
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      throw AntigravityError.notSignedIn
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      throw AntigravityError.notSignedIn
    }
    return text
  }

  static func describe(_ error: Error) -> String {
    switch error {
    case AntigravityError.notSignedIn:
      return "not signed in to Antigravity"
    case AntigravityError.tokenExpired:
      return "token expired — sign in to refresh"
    case let AntigravityError.fetchFailed(code?, retryAfter):
      if code == 401 {
        return "token rejected — open Antigravity to refresh"
      }
      if code == 429, let retryAfter {
        return "usage fetch rate-limited; retry after \(ProviderResult.compactDuration(retryAfter))"
      }
      return "usage fetch failed (HTTP \(code))"
    case AntigravityError.fetchFailed(nil, _):
      return "usage fetch failed"
    case AntigravityError.malformed:
      return "unexpected Antigravity usage format"
    default:
      return String(describing: error)
    }
  }

  private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
    guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
      .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    if let seconds = Double(raw) {
      return max(0, seconds)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
    guard let date = formatter.date(from: raw) else {
      return nil
    }
    return max(0, date.timeIntervalSinceNow)
  }

  private static func parseISO(_ string: String) -> Date? {
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractional.date(from: string) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: string)
  }
}

struct AntigravityCredential: Sendable {
  let accessToken: String
  let expiresAt: Date?
  let refreshToken: String?
}

enum AntigravityError: Error {
  case notSignedIn
  case tokenExpired
  case fetchFailed(Int?, retryAfter: TimeInterval?)
  case malformed
}

/// Decoder for Google Cloud Code PA's `retrieveUserQuotaSummary` response.
/// Groups provide the broad 5-hour and weekly Gemini limits, plus secondary
/// model buckets surfaced as menu rows.
enum AntigravityUsageParser {
  static func windows(from payload: [String: Any], now: Date) -> [UsageWindow] {
    guard let groups = payload["groups"] as? [[String: Any]], !groups.isEmpty else {
      return []
    }

    var windows: [UsageWindow] = []

    // Primary group is Gemini models
    let primaryGroup = groups.first { group in
      let name = (group["displayName"] as? String)?.lowercased() ?? ""
      return name.contains("gemini")
    } ?? groups[0]

    let primaryBuckets = primaryGroup["buckets"] as? [[String: Any]] ?? []
    for bucket in primaryBuckets {
      guard let window = parseBucket(bucket, isPrimary: true, now: now) else {
        continue
      }
      windows.append(window)
    }

    // Non-primary groups (e.g. 3P Claude/GPT models) surface as menu rows
    for group in groups where (group["displayName"] as? String) != (primaryGroup["displayName"] as? String) {
      let groupName = (group["displayName"] as? String) ?? "Other Models"
      let buckets = group["buckets"] as? [[String: Any]] ?? []
      for bucket in buckets {
        guard let window = parseBucket(bucket, isPrimary: false, groupName: groupName, now: now) else {
          continue
        }
        windows.append(window)
      }
    }

    return windows
  }

  static func hasCompleteBroadWindows(_ windows: [UsageWindow]) -> Bool {
    windows.contains { $0.scope == nil && $0.speed == .fast }
      && windows.contains { $0.scope == nil && $0.speed == .slow }
  }

  private static func parseBucket(
    _ bucket: [String: Any],
    isPrimary: Bool,
    groupName: String? = nil,
    now: Date
  ) -> UsageWindow? {
    let bucketId = (bucket["bucketId"] as? String) ?? ""
    let windowType = (bucket["window"] as? String)?.lowercased() ?? ""
    let isWeekly = windowType == "weekly" || bucketId.contains("weekly")
    let speed: WindowSpeed = isWeekly ? .slow : .fast
    let defaultDuration: TimeInterval = isWeekly ? 7 * 24 * 3600 : 5 * 3600

    let remainingFraction: Double
    if let frac = numeric(bucket["remainingFraction"]) ?? numeric(bucket["remaining_fraction"]) {
      remainingFraction = min(1.0, max(0.0, frac))
    } else {
      remainingFraction = 0.0
    }
    let usedPercent = (1.0 - remainingFraction) * 100.0

    let resetAt: Date
    if let resetTimeStr = (bucket["resetTime"] as? String) ?? (bucket["reset_time"] as? String),
      let parsed = parseISO(resetTimeStr)
    {
      resetAt = parsed
    } else {
      resetAt = now.addingTimeInterval(defaultDuration)
    }

    let scope: UsageScope?
    let visualStyle: UsageVisualStyle
    if isPrimary {
      scope = nil
      visualStyle = .hand
    } else {
      let bucketDisplayName = (bucket["displayName"] as? String) ?? bucketId
      let label = isWeekly ? "\(bucketDisplayName) (Weekly)" : "\(bucketDisplayName) (5h)"
      scope = UsageScope(kind: "group", key: bucketId, displayName: label)
      visualStyle = .menuRow
    }

    return PressureMath.window(
      provider: .antigravity,
      speed: speed,
      usedPercent: usedPercent,
      resetAt: resetAt,
      limitWindowSeconds: defaultDuration,
      now: now,
      scope: scope,
      visualStyle: visualStyle
    )
  }

  private static func numeric(_ value: Any?) -> Double? {
    if let double = value as? Double { return double }
    if let int = value as? Int { return Double(int) }
    if let string = value as? String { return Double(string) }
    return nil
  }

  private static func parseISO(_ string: String) -> Date? {
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractional.date(from: string) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: string)
  }
}
