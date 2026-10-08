import Foundation
import CryptoKit
import OSLog

/// Reads Claude plan usage by running Claude Code's own headless `/usage`
/// command:
///
///     claude -p /usage --output-format json --no-session-persistence
///
/// `/usage` is a local command. Claude Code answers it without a model turn
/// (`num_turns` 0, cost 0, about a second) and handles its own login and token
/// renewal. Alight therefore never reads Claude credentials, never calls
/// Anthropic endpoints itself, and never presents itself as another client.
///
/// Each poll first runs `claude auth status --json` to learn which account
/// the reading belongs to. Only a domain-separated SHA-256 of the account's
/// email and organization leaves this file; the cache uses it to discard
/// readings from a different (or unknown) login. Any output Alight cannot
/// fully verify becomes an explicit failure. It never becomes a guessed number.
struct ClaudeUsageClient: Sendable {
  /// `--no-session-persistence` keeps each poll from saving a resumable
  /// session transcript under `~/.claude/projects/`.
  static let usageArguments = ["-p", "/usage", "--output-format", "json", "--no-session-persistence"]
  static let authStatusArguments = ["auth", "status", "--json"]
  static let timeout: TimeInterval = 30
  static let outputLimit = 256 * 1024
  /// Result `source` when Claude Code answered `/usage` with a model turn.
  /// The store stops scheduled Claude polls after it, so a CLI that stops
  /// treating `/usage` as a local command cannot spend inference every poll.
  static let refusedSource = "refused"
  static let identitySource = "claude-code:/usage"

  private static let logger = Logger(subsystem: "com.owlandkestrel.alight", category: "usage")

  var environment: [String: String] = ProcessInfo.processInfo.environment
  var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  var workingDirectory: URL = ClaudeUsageClient.defaultWorkingDirectory
  var runner: BoundedProcessRunner = .shared
  var timeout: TimeInterval = ClaudeUsageClient.timeout

  func result(now: Date = Date()) async -> ProviderResult {
    let executable: String
    switch Self.resolveExecutable(
      environment: environment,
      homeDirectory: homeDirectory,
      isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
    case .found(let path):
      executable = path
    case .overrideNotExecutable:
      return .failure(.claude, source: "error", error: "ALIGHT_CLAUDE_BIN is not an executable file")
    case .notFound:
      return .failure(.claude, source: "error", error: "Claude Code CLI not found (install it or set ALIGHT_CLAUDE_BIN)")
    }
    do {
      try FileManager.default.createDirectory(
        at: workingDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      return .failure(.claude, source: "error", error: "cannot create Alight's working directory")
    }
    let childEnvironment = Self.childEnvironment(
      executable: executable,
      homeDirectory: homeDirectory,
      user: NSUserName()
    )

    // `auth status` exits 1 when signed out but still prints its JSON.
    let auth = await run(executable, Self.authStatusArguments, environment: childEnvironment)
    switch auth.failure {
    case .launchFailed:
      return .failure(.claude, source: "error", error: "could not start the Claude Code CLI")
    case .timedOut:
      // A CLI that hangs here would hang on /usage too; do not wait twice.
      return .failure(.claude, source: "error", error: "Claude Code auth status timed out")
    default:
      break
    }
    let status = auth.failure == nil ? ClaudeAuthStatus.parse(auth.stdout) : nil
    if let status, !status.loggedIn {
      return .failure(.claude, source: "error", error: "not signed in to Claude Code", needsAuth: true)
    }
    let identity = status?.identity
    if identity == nil {
      Self.logger.info("Claude account identity unavailable; reading will not be cached")
    }

    let usage = await run(executable, Self.usageArguments, environment: childEnvironment)
    var result = Self.result(from: usage, now: max(now, Date()))
    result.observationIdentity = identity
    return result
  }

  private func run(_ executable: String, _ arguments: [String], environment: [String: String]) async -> BoundedProcessRunner.Result {
    await runner.run(
      executable: executable,
      arguments: arguments,
      environment: environment,
      directory: workingDirectory.path,
      timeout: timeout,
      outputLimit: Self.outputLimit
    )
  }

  /// Maps one finished `/usage` run onto a provider result.
  static func result(from run: BoundedProcessRunner.Result, now: Date) -> ProviderResult {
    if let failure = run.failure {
      let message = switch failure {
      case .launchFailed: "could not start the Claude Code CLI"
      case .timedOut: "Claude Code /usage timed out"
      case .outputLimitExceeded: "Claude Code /usage output too large"
      case .outputIncomplete, .signaled: "Claude Code /usage did not finish cleanly"
      }
      return .failure(.claude, source: "error", error: message)
    }

    do {
      let windows = try ClaudeUsageParser.windows(fromCommandOutput: run.stdout, now: now)
      return ProviderResult(provider: .claude, ok: true, source: "live", error: nil, windows: windows)
    } catch ClaudeUsageParser.Failure.notJSON where run.status != 0 {
      // Usually a CLI that rejected its arguments. Its own first stderr line
      // is the most useful explanation.
      let detail = firstLine(of: run.stderr)
      if let detail, ClaudeUsageParser.mentionsSignIn(detail) {
        return .failure(.claude, source: "error", error: "not signed in to Claude Code", needsAuth: true)
      }
      let status = run.status.map(String.init) ?? "?"
      return .failure(
        .claude,
        source: "error",
        error: "Claude Code exited with status \(status)" + (detail.map { ": \($0)" } ?? "")
      )
    } catch let failure as ClaudeUsageParser.Failure {
      return .failure(
        .claude,
        source: failure == .modelTurn ? refusedSource : "error",
        error: failure.message,
        needsAuth: failure == .notSignedIn
      )
    } catch {
      return .failure(.claude, source: "error", error: "unexpected Claude Code /usage output")
    }
  }

  // MARK: - CLI location and environment

  enum ExecutableResolution: Equatable {
    case found(String)
    case overrideNotExecutable
    case notFound
  }

  /// `ALIGHT_CLAUDE_BIN` first, then the standard install locations. A login
  /// item does not inherit the user's shell `PATH`, so there is no PATH search.
  static func resolveExecutable(
    environment: [String: String],
    homeDirectory: URL,
    isExecutable: (String) -> Bool
  ) -> ExecutableResolution {
    if let raw = environment["ALIGHT_CLAUDE_BIN"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
      let path = (raw as NSString).expandingTildeInPath
      return path.hasPrefix("/") && isExecutable(path) ? .found(path) : .overrideNotExecutable
    }
    let home = homeDirectory.path
    let candidates = [
      "\(home)/.local/bin/claude",
      "/opt/homebrew/bin/claude",
      "/usr/local/bin/claude",
      "\(home)/.claude/local/claude",
    ]
    return candidates.first(where: isExecutable).map(ExecutableResolution.found) ?? .notFound
  }

  /// A minimal, secret-free environment. Nothing from Alight's own
  /// environment is forwarded, so variables such as `CLAUDE_CODE_OAUTH_TOKEN`
  /// or `ANTHROPIC_API_KEY` cannot switch Claude Code to another login.
  /// - `PATH` adds the CLI's own directory, where an npm install finds `node`.
  /// - `LANG` is fixed so reset dates are always rendered in English.
  /// - `DISABLE_AUTOUPDATER` keeps a usage poll from updating Claude Code.
  static func childEnvironment(executable: String, homeDirectory: URL, user: String) -> [String: String] {
    let binDirectory = (executable as NSString).deletingLastPathComponent
    return [
      "HOME": homeDirectory.path,
      "USER": user,
      "PATH": "/usr/bin:/bin:\(binDirectory)",
      "LANG": "en_US.UTF-8",
      "DISABLE_AUTOUPDATER": "1",
    ]
  }

  /// Claude Code is run from Alight's own Application Support folder, so it
  /// never picks up project settings or instructions from an arbitrary folder.
  static var defaultWorkingDirectory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
    return base.appending(path: "Alight", directoryHint: .isDirectory)
  }

  private static func firstLine(of data: Data) -> String? {
    let line = String(decoding: data, as: UTF8.self)
      .split(whereSeparator: \.isNewline)
      .lazy
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty }
    return line.map { String($0.prefix(120)) }
  }
}

/// The account a reading belongs to, from `claude auth status --json`.
struct ClaudeAuthStatus: Equatable {
  let loggedIn: Bool
  /// Nil when the account cannot be identified. Readings without an identity
  /// are shown live but never cached.
  let identity: UsageObservationIdentity?

  private struct Payload: Decodable {
    let loggedIn: Bool
    let email: String?
    let orgId: String?
    let subscriptionType: String?
  }

  static func parse(_ data: Data) -> ClaudeAuthStatus? {
    guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
      return nil
    }
    guard payload.loggedIn else {
      return ClaudeAuthStatus(loggedIn: false, identity: nil)
    }
    return ClaudeAuthStatus(
      loggedIn: true,
      identity: observationIdentity(email: payload.email, orgId: payload.orgId, subscriptionType: payload.subscriptionType)
    )
  }

  /// A domain-separated digest of the account email and organization. The raw
  /// email never leaves this function. The plan name (`team`, `max`, …) is
  /// the limit identity, so a plan change also breaks continuity.
  static func observationIdentity(email: String?, orgId: String?, subscriptionType: String?) -> UsageObservationIdentity? {
    guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !email.isEmpty else {
      return nil
    }
    let organization = orgId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let digest = SHA256.hash(data: Data("alight.usage-account.v1\u{0}claude\u{0}\(organization)\u{0}\(email)".utf8))
    let plan = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return UsageObservationIdentity(
      source: ClaudeUsageClient.identitySource,
      accountPartition: digest.map { String(format: "%02x", $0) }.joined(),
      limitIdentity: plan?.isEmpty == false ? plan : nil
    )
  }
}

/// Validates the JSON from `claude -p /usage --output-format json` and parses
/// its text into usage windows. The text lists the plan's limits:
///
///     Current session: 16% used · resets Oct 8 at 2pm (America/Guayaquil)
///     Current week (all models): 40% used · resets Oct 14 at 9am (America/Guayaquil)
///     Current week (Fable): 0% used · resets Oct 8 at 7pm (America/Guayaquil)
///
/// `Current session` is the five-hour window, `Current week (all models)` the
/// weekly window, and `Current week (<Model>)` a model-scoped weekly window.
/// Fable keeps its outer-edge star; every other model is a dropdown row. A
/// plan may have no `all models` weekly line (a Team seat, for example): the
/// command prints every limit the plan has, so a session-only reading is
/// complete. Other lines (the usage breakdown) are ignored.
enum ClaudeUsageParser {
  static let sessionDuration: TimeInterval = 5 * 3600
  static let weekDuration: TimeInterval = 7 * 24 * 3600

  enum Failure: Error, Equatable {
    case notJSON
    case unexpectedShape
    case modelTurn
    case notUsageCommand
    case commandFailed(String)
    case notSignedIn
    case noPlanLimits
    case noLimits
    case unrecognizedLine(String)

    var message: String {
      switch self {
      case .notJSON: "unexpected Claude Code /usage output"
      case .unexpectedShape: "unexpected Claude Code /usage result"
      case .modelTurn: "stopped: Claude Code answered /usage with a model turn; update Claude Code, then Refresh"
      case .notUsageCommand: "Claude Code did not run its local /usage command"
      case .commandFailed(let detail): "Claude Code /usage failed: \(detail)"
      case .notSignedIn: "not signed in to Claude Code"
      case .noPlanLimits: "Claude Code reports no plan usage limits for this login"
      case .noLimits: "no usage limits in Claude Code /usage output"
      case .unrecognizedLine(let label): "unrecognized Claude Code usage line: \(label)"
      }
    }
  }

  private struct CommandResult: Decodable {
    let type: String
    let subtype: String?
    let isError: Bool?
    let numTurns: Int?
    let totalCostUsd: Double?
    let localCommand: String?
    let result: String?

    enum CodingKeys: String, CodingKey {
      case type, subtype, result
      case isError = "is_error"
      case numTurns = "num_turns"
      case totalCostUsd = "total_cost_usd"
      case localCommand = "local_command"
    }
  }

  static func windows(fromCommandOutput data: Data, now: Date) throws -> [UsageWindow] {
    guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
      throw Failure.notJSON
    }
    guard let command = try? JSONDecoder().decode(CommandResult.self, from: data), command.type == "result" else {
      throw Failure.unexpectedShape
    }
    // Refuse before reading anything else: a model turn means the CLI did not
    // treat `/usage` as a local command, so the text is not a usage report.
    guard let turns = command.numTurns else {
      throw Failure.unexpectedShape
    }
    if turns != 0 || (command.totalCostUsd ?? 0) > 0 {
      throw Failure.modelTurn
    }
    let text = command.result ?? ""
    guard command.subtype == "success", command.isError != true else {
      if mentionsSignIn(text) { throw Failure.notSignedIn }
      let detail = text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(120)) }
      throw Failure.commandFailed(detail ?? command.subtype ?? "error")
    }
    guard command.localCommand == "usage" else {
      throw Failure.notUsageCommand
    }
    return try windows(fromText: text, now: now)
  }

  static func windows(fromText text: String, now: Date) throws -> [UsageWindow] {
    var windows: [UsageWindow] = []
    var seen: Set<String> = []
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard let colon = line.firstIndex(of: ":") else { continue }
      let label = line[..<colon].trimmingCharacters(in: .whitespaces)
      let value = String(line[line.index(after: colon)...])
      guard let kind = LineKind(label: label) else { continue }
      let window = try window(kind: kind, label: label, value: value, now: now)
      // First occurrence wins so duplicates stay deterministic.
      if seen.insert(window.id).inserted {
        windows.append(window)
      }
    }
    guard windows.contains(where: { $0.scope == nil }) else {
      if mentionsSignIn(text) { throw Failure.notSignedIn }
      // Without a subscription login, `/usage` prints a session cost summary.
      if text.range(of: "Total cost:", options: .caseInsensitive) != nil { throw Failure.noPlanLimits }
      throw Failure.noLimits
    }
    return windows
  }

  static func mentionsSignIn(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return ["not logged in", "/login", "log in", "sign in", "invalid api key", "oauth token"]
      .contains { lowered.contains($0) }
  }

  private enum LineKind {
    case session
    case week
    case model(String)

    var isSession: Bool {
      if case .session = self { return true }
      return false
    }

    init?(label: String) {
      let lowered = label.lowercased()
      if lowered == "current session" {
        self = .session
        return
      }
      guard lowered.hasPrefix("current week") else { return nil }
      let rest = label.dropFirst("current week".count).trimmingCharacters(in: .whitespaces)
      if rest.isEmpty {
        self = .week
        return
      }
      guard rest.hasPrefix("("), rest.hasSuffix(")") else { return nil }
      var name = rest.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
      if name.lowercased() == "all models" {
        self = .week
        return
      }
      if name.lowercased().hasSuffix(" only") {
        name = String(name.dropLast(" only".count)).trimmingCharacters(in: .whitespaces)
      }
      guard !name.isEmpty else { return nil }
      self = .model(name)
    }
  }

  private static func window(kind: LineKind, label: String, value: String, now: Date) throws -> UsageWindow {
    guard let usedPercent = usedPercent(in: value) else {
      throw Failure.unrecognizedLine(label)
    }
    let duration: TimeInterval
    var scope: UsageScope?
    var style = UsageVisualStyle.hand
    switch kind {
    case .session:
      duration = sessionDuration
    case .week:
      duration = weekDuration
    case .model(let name):
      duration = weekDuration
      // Fable keeps its dedicated scope so earlier cached readings and the
      // dial's star keep their identity.
      if name.localizedCaseInsensitiveCompare("Fable") == .orderedSame {
        scope = .fable
        style = .outerStar
      } else {
        scope = UsageScope.modelScope(displayName: name)
        style = .menuRow
      }
      guard scope != nil else { throw Failure.unrecognizedLine(label) }
    }

    let resetAt: Date
    if let clause = resetClause(in: value) {
      guard let parsed = ClaudeResetTime.parse(clause, now: now) else {
        throw Failure.unrecognizedLine(label)
      }
      resetAt = parsed
    } else if usedPercent == 0 {
      // An unused window may not have started; treat it as a fresh window.
      resetAt = now.addingTimeInterval(duration)
    } else {
      throw Failure.unrecognizedLine(label)
    }
    // A reset far outside the window's own length is a misread, not data.
    guard resetAt > now.addingTimeInterval(-24 * 3600),
      resetAt <= now.addingTimeInterval(duration + 24 * 3600) else {
      throw Failure.unrecognizedLine(label)
    }

    return PressureMath.window(
      provider: .claude,
      speed: kind.isSession ? .fast : .slow,
      usedPercent: usedPercent,
      resetAt: resetAt,
      limitWindowSeconds: duration,
      now: now,
      scope: scope,
      visualStyle: style
    )
  }

  /// `16% used` is used; `84% left` / `84% remaining` is converted.
  private static func usedPercent(in value: String) -> Double? {
    guard let match = value.firstMatch(of: /(?i)(\d+(?:\.\d+)?)\s*%\s*(used|left|remaining)/),
      let number = Double(match.1), number.isFinite else {
      return nil
    }
    let percent = match.2.lowercased() == "used" ? number : 100 - number
    return min(100, max(0, percent))
  }

  private static func resetClause(in value: String) -> String? {
    guard let match = value.firstMatch(of: /(?i)\bresets?\s+(.+)$/) else {
      return nil
    }
    return String(match.1).trimmingCharacters(in: .whitespaces)
  }
}

/// Parses Claude Code's reset phrases into absolute times:
/// `Oct 8 at 2pm (America/Guayaquil)`, `Oct 8, 2:30pm (…)`, `Oct 8 at 14:00`,
/// `2pm (…)` (next occurrence), `Oct 8 (…)` (midnight), and `in 3h 12m`.
/// The time zone is the IANA name in parentheses; without one, the system
/// zone the CLI also used. A date with no year takes the year that puts it
/// closest to `now`, so a December poll reads `Jan 2` as next year.
enum ClaudeResetTime {
  static func parse(_ clause: String, now: Date) -> Date? {
    var text = clause.trimmingCharacters(in: .whitespacesAndNewlines)
    while let last = text.last, ".,;".contains(last) { text.removeLast() }

    if let match = text.firstMatch(of: /(?i)^in\s+(.+)$/) {
      return relativeInterval(String(match.1)).map { now.addingTimeInterval($0) }
    }

    var timeZone = TimeZone.current
    if let match = text.firstMatch(of: /\(([^()]+)\)\s*$/) {
      guard let zone = TimeZone(identifier: match.1.trimmingCharacters(in: .whitespaces)) else {
        return nil
      }
      timeZone = zone
      text = String(text[..<match.range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    guard let match = text.firstMatch(
      of: /(?i)^(?:([a-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?)?\s*(?:(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?)?$/
    ) else {
      return nil
    }
    let month = match.1.flatMap { monthNumber(String($0)) }
    if match.1 != nil && month == nil { return nil }
    let day = match.2.flatMap { Int($0) }

    var hour = 0
    var minute = 0
    let hasTime = match.3 != nil
    if let rawHour = match.3.flatMap({ Int($0) }) {
      minute = match.4.flatMap { Int($0) } ?? 0
      guard minute < 60 else { return nil }
      if let meridiem = match.5?.lowercased() {
        guard (1...12).contains(rawHour) else { return nil }
        hour = rawHour % 12 + (meridiem == "pm" ? 12 : 0)
      } else {
        // A bare hour is ambiguous; a 24-hour time needs its minutes.
        guard match.4 != nil, (0...23).contains(rawHour) else { return nil }
        hour = rawHour
      }
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone

    if let month, let day {
      let year = calendar.component(.year, from: now)
      let candidates = [year - 1, year, year + 1].compactMap { candidateYear -> Date? in
        let components = DateComponents(year: candidateYear, month: month, day: day, hour: hour, minute: minute)
        guard let date = calendar.date(from: components),
          calendar.component(.month, from: date) == month,
          calendar.component(.day, from: date) == day else {
          return nil
        }
        return date
      }
      return candidates.min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
    }

    // Time only: the next occurrence of that wall-clock time.
    guard hasTime else { return nil }
    var components = calendar.dateComponents([.year, .month, .day], from: now)
    components.hour = hour
    components.minute = minute
    guard let today = calendar.date(from: components) else { return nil }
    return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
  }

  /// `3h 12m`, `2d 4h`, `45m`, `1 hour 5 minutes`.
  static func relativeInterval(_ text: String) -> TimeInterval? {
    var remaining = Substring(text.lowercased())
    var total: TimeInterval = 0
    var matchedAny = false
    while true {
      remaining = remaining.drop { $0 == " " || $0 == "," }
      if remaining.hasPrefix("and ") { remaining = remaining.dropFirst(4); continue }
      if remaining.isEmpty { break }
      guard let match = remaining.prefixMatch(of: /(\d+)\s*(days?|d|hours?|hrs?|h|minutes?|mins?|m)\b/),
        let amount = Double(match.1) else {
        return nil
      }
      let unit: TimeInterval = switch match.2.first {
      case "d": 24 * 3600
      case "h": 3600
      default: 60
      }
      total += amount * unit
      matchedAny = true
      remaining = remaining[match.range.upperBound...]
    }
    return matchedAny ? total : nil
  }

  private static func monthNumber(_ name: String) -> Int? {
    let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    let lowered = name.lowercased()
    guard let index = months.firstIndex(where: { lowered.hasPrefix($0) }) else {
      return nil
    }
    // Accept `Oct`, `October`, `Sept`; reject words that merely start alike.
    let full = ["january", "february", "march", "april", "may", "june", "july",
      "august", "september", "october", "november", "december"][index]
    return full.hasPrefix(lowered) ? index + 1 : nil
  }
}
