import Foundation
import CryptoKit
import OSLog

/// Reads Claude plan usage by running Claude Code's own headless `/usage`
/// command:
///
///     claude -p /usage --output-format json --no-session-persistence --safe-mode
///
/// `/usage` is a local command. Claude Code answers it without a model turn
/// (`num_turns` 0, cost 0; measured at 2-4 s and about 1.8 CPU-seconds) and
/// handles its own login and token renewal. Alight therefore never reads
/// Claude credentials, never calls Anthropic endpoints itself, and never
/// presents itself as another client.
///
/// Each poll first runs `claude auth status --json` to learn which account
/// the reading belongs to. Only a domain-separated SHA-256 of the account's
/// email and organization leaves this file; the cache uses it to discard
/// readings from a different (or unknown) login. Any output Alight cannot
/// fully verify becomes an explicit failure. It never becomes a guessed number.
struct ClaudeUsageClient: Sendable {
  /// `--no-session-persistence` keeps each poll from saving a resumable
  /// session transcript under `~/.claude/projects/`. `--safe-mode` keeps it
  /// from loading the user's hooks, plugins, and MCP servers, which would
  /// otherwise start (and fire SessionStart/SessionEnd hooks) on every poll.
  /// Login and the built-in `/usage` command work normally in safe mode.
  static let usageArguments = ["-p", "/usage", "--output-format", "json", "--no-session-persistence", "--safe-mode"]
  static let authStatusArguments = ["auth", "status", "--json"]
  static let timeout: TimeInterval = 30
  static let outputLimit = 256 * 1024
  /// Result `source` when Claude Code answered `/usage` with a model turn.
  /// The store stops scheduled Claude polls after it, so a CLI that stops
  /// treating `/usage` as a local command cannot spend inference every poll.
  static let refusedSource = "refused"
  /// Result `source` when `auth status` reported a signed-out CLI. Only that
  /// cheap, local check ran, so the store rechecks every minute and reads
  /// usage as soon as the user signs in.
  static let signedOutSource = "signed-out"
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
      isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
      listDirectory: { try? FileManager.default.contentsOfDirectory(atPath: $0) }
    ) {
    case .found(let path):
      executable = path
    case .overrideNotExecutable:
      return .failure(.claude, source: "error", error: "ALIGHT_CLAUDE_CLI is not an executable file")
    case .notFound:
      return .failure(.claude, source: "error", error: "Claude Code CLI not found (install it or set ALIGHT_CLAUDE_CLI)")
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
      user: NSUserName(),
      temporaryDirectory: NSTemporaryDirectory()
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
      return .failure(
        .claude, source: Self.signedOutSource, error: "not signed in to Claude Code", needsAuth: true,
        failureCode: .authRequired
      )
    }
    let identity = status?.identity
    if identity == nil {
      Self.logger.info("Claude account identity unavailable; reading will not be cached")
    }

    let usage = await run(executable, Self.usageArguments, environment: childEnvironment)
    var result = Self.result(from: usage, now: max(now, Date()))
    result.observationIdentity = identity
    result.accountRef = status?.accountRef
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
      case .outputIncomplete, .signaled, .statusUnavailable: "Claude Code /usage did not finish cleanly"
      }
      return .failure(.claude, source: "error", error: message)
    }

    do {
      let reading = try ClaudeUsageParser.reading(fromCommandOutput: run.stdout, now: now)
      var result = ProviderResult(provider: .claude, ok: true, source: "live", error: nil, windows: reading.windows)
      result.quotaReport = reading.report
      return result
    } catch ClaudeUsageParser.Failure.notJSON where run.status != 0 {
      // Usually a CLI that rejected its arguments. Its own first stderr line
      // is the most useful explanation.
      let detail = firstLine(of: run.stderr)
      if let detail, ClaudeUsageParser.mentionsSignIn(detail) {
        return .failure(
          .claude, source: "error", error: "not signed in to Claude Code", needsAuth: true, failureCode: .authRequired)
      }
      if let detail, detail.localizedCaseInsensitiveContains("unknown option") {
        // An older CLI that lacks a flag Alight passes.
        return .failure(.claude, source: "error", error: "update Claude Code (\(detail))")
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
        needsAuth: failure == .notSignedIn,
        failureCode: failure.exportCode
      )
    } catch {
      return .failure(.claude, source: "error", error: "unexpected Claude Code /usage output", failureCode: .parseFailed)
    }
  }

  // MARK: - CLI location and environment

  enum ExecutableResolution: Equatable {
    case found(String)
    case overrideNotExecutable
    case notFound
  }

  /// `ALIGHT_CLAUDE_CLI` first, then the standard install locations and the
  /// usual Node version managers (Volta, Bun, the newest nvm Node). A login
  /// item does not inherit the user's shell `PATH`, so there is no PATH search
  /// and no shell lookup.
  static func resolveExecutable(
    environment: [String: String],
    homeDirectory: URL,
    isExecutable: (String) -> Bool,
    listDirectory: (String) -> [String]?
  ) -> ExecutableResolution {
    if let raw = environment["ALIGHT_CLAUDE_CLI"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
      let path = (raw as NSString).expandingTildeInPath
      return path.hasPrefix("/") && isExecutable(path) ? .found(path) : .overrideNotExecutable
    }
    let home = homeDirectory.path
    var candidates = [
      "\(home)/.local/bin/claude",
      "/opt/homebrew/bin/claude",
      "/usr/local/bin/claude",
      "\(home)/.claude/local/claude",
      "\(home)/.volta/bin/claude",
      "\(home)/.bun/bin/claude",
    ]
    let nvmVersions = "\(home)/.nvm/versions/node"
    candidates += (listDirectory(nvmVersions) ?? [])
      .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
      .map { "\(nvmVersions)/\($0)/bin/claude" }
    return candidates.first(where: isExecutable).map(ExecutableResolution.found) ?? .notFound
  }

  /// A minimal, secret-free environment. Nothing from Alight's own
  /// environment is forwarded, so variables such as `CLAUDE_CODE_OAUTH_TOKEN`
  /// or `ANTHROPIC_API_KEY` cannot switch Claude Code to another login.
  /// - `PATH` adds the CLI's own directory, where an npm install finds `node`.
  /// - `TMPDIR` is the per-user temporary folder rather than the shared `/tmp`.
  /// - `LANG` is fixed so reset dates are always rendered in English.
  /// - `DISABLE_AUTOUPDATER` keeps a usage poll from updating Claude Code.
  static func childEnvironment(executable: String, homeDirectory: URL, user: String,
    temporaryDirectory: String) -> [String: String] {
    let binDirectory = (executable as NSString).deletingLastPathComponent
    return [
      "HOME": homeDirectory.path,
      "USER": user,
      "PATH": "/usr/bin:/bin:\(binDirectory)",
      "TMPDIR": temporaryDirectory,
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
  /// Fieldbook `usageAccountRef` of the same email and organization, for the
  /// quota snapshot export. Nil exactly when `identity` is.
  var accountRef: String? = nil

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
    let identity = observationIdentity(email: payload.email, orgId: payload.orgId, subscriptionType: payload.subscriptionType)
    return ClaudeAuthStatus(
      loggedIn: true,
      identity: identity,
      accountRef: identity == nil ? nil : UsageAccountRef.digest(
        provider: .claude, organization: payload.orgId, identifier: payload.email, kind: .email)
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
/// Claude Code prints one `<title>: <floor(utilization)>% used` line per limit,
/// followed by ` · resets <date>` when the limit has a reset time.
/// `Current session` is the five-hour window, `Current week (all models)` the
/// weekly window, and `Current week (<Model>)` a model-scoped weekly window
/// (`Sonnet only` on Max and Team plans, `Fable`, and any other model the
/// account reports). Fable keeps its outer-edge star; every other model is a
/// dropdown row. A plan may have no `all models` weekly line (a Team seat, for
/// example): the command prints every limit the plan has, so a session-only
/// reading is complete. Other lines (the usage breakdown, spend limits) are
/// ignored.
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
      case .modelTurn: "Stopped: /usage ran a model turn. Update Claude Code, then Refresh"
      case .notUsageCommand: "Claude Code did not run its local /usage command"
      case .commandFailed(let detail): "Claude Code /usage failed: \(detail)"
      case .notSignedIn: "not signed in to Claude Code"
      case .noPlanLimits: "Claude Code reports no plan usage limits for this login"
      case .noLimits: "no usage limits in Claude Code /usage output"
      case .unrecognizedLine(let label): "unrecognized Claude Code usage line: \(label)"
      }
    }

    /// The quota snapshot's closed failure code for this failure.
    var exportCode: ProviderFailureCode {
      switch self {
      case .notSignedIn: .authRequired
      case .modelTurn: .refused
      case .notJSON, .unexpectedShape, .notUsageCommand, .noLimits, .unrecognizedLine: .parseFailed
      case .commandFailed, .noPlanLimits: .unknown
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

  /// Display windows plus the provider-reported facts behind them (see
  /// `QuotaReport`). The report is nil when a reported value cannot be
  /// exported unclamped (a `left` figure above 100).
  struct Reading {
    let windows: [UsageWindow]
    let report: QuotaReport?
  }

  static func windows(fromCommandOutput data: Data, now: Date) throws -> [UsageWindow] {
    try reading(fromCommandOutput: data, now: now).windows
  }

  static func reading(fromCommandOutput data: Data, now: Date) throws -> Reading {
    guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
      throw Failure.notJSON
    }
    guard let command = try? JSONDecoder().decode(CommandResult.self, from: data), command.type == "result" else {
      throw Failure.unexpectedShape
    }
    // Refuse before reading anything else: a model turn means the CLI did not
    // treat `/usage` as a local command, so the text is not a usage report. A
    // result without a turn count cannot rule a model turn out, so it is
    // refused too rather than retried every poll.
    guard let turns = command.numTurns, turns == 0, (command.totalCostUsd ?? 0) <= 0 else {
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
    return try reading(fromText: text, now: now)
  }

  static func windows(fromText text: String, now: Date) throws -> [UsageWindow] {
    try reading(fromText: text, now: now).windows
  }

  static func reading(fromText text: String, now: Date) throws -> Reading {
    var windows: [UsageWindow] = []
    var reported: [QuotaReportWindow] = []
    var reportValid = true
    var seen: Set<String> = []
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      let lowered = line.lowercased()
      guard lowered.hasPrefix("current session") || lowered.hasPrefix("current week") else {
        continue
      }
      // The label ends at the colon before the percentage, so a model name
      // that itself contains a colon (`Current week (Fable: Pro): 7% used`)
      // stays whole instead of becoming an unknown label.
      let percent = line.firstMatch(of: /(?i):\s*(\d+(?:\.\d+)?)\s*%\s*(used|left|remaining)\b/)
      let labelEnd = percent?.range.lowerBound ?? line.firstIndex(of: ":") ?? line.endIndex
      let label = String(line[..<labelEnd].prefix(60)).trimmingCharacters(in: .whitespaces)
      // A limit line that cannot be classified or read fails the whole
      // reading: dropping it could hide an active limit, or make a weekly
      // plan look session-only.
      guard let kind = LineKind(label: label), let percent, let number = Double(percent.1), number.isFinite else {
        throw Failure.unrecognizedLine(label)
      }
      let reportsUsed = percent.2.lowercased() == "used"
      let used = reportsUsed ? number : 100 - number
      let (window, report) = try window(
        kind: kind,
        label: label,
        usedPercent: min(100, max(0, used)),
        rest: String(line[percent.range.upperBound...]),
        now: now
      )
      // First occurrence wins so duplicates stay deterministic.
      if seen.insert(window.id).inserted {
        windows.append(window)
        // The export keeps the printed figure unclamped. Claude Code prints
        // `floor(utilization)% used`, so a whole `used` figure is a floor; a
        // `left` figure or a decimal has no proven rounding.
        if used.isFinite, used >= 0 {
          reported.append(QuotaReportWindow(
            windowSeconds: report.windowSeconds,
            windowSecondsSource: .label,
            usedPercentRaw: used,
            usedPercentPrecision: reportsUsed && !percent.1.contains(".") ? .floorInteger : .unverified,
            resetAt: report.resetAt,
            providerBucketId: nil,
            scope: window.scope
          ))
        } else {
          reportValid = false
        }
      }
    }
    guard windows.contains(where: { $0.scope == nil }) else {
      if mentionsSignIn(text) { throw Failure.notSignedIn }
      // Without a subscription login, `/usage` prints a session cost summary.
      if text.range(of: "Total cost:", options: .caseInsensitive) != nil { throw Failure.noPlanLimits }
      throw Failure.noLimits
    }
    let report = reportValid ? QuotaReport(groups: [QuotaReportGroup(providerGroup: nil, windows: reported)]) : nil
    return Reading(windows: windows, report: report)
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

  /// The display window, plus the reported length and reset for the export:
  /// the reset as printed (nil when Claude Code printed none), before the
  /// display substitutes a fresh window for a missing or passed reset.
  private static func window(kind: LineKind, label: String, usedPercent: Double, rest: String, now: Date) throws
    -> (UsageWindow, (windowSeconds: Int, resetAt: Date?)) {
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

    var used = usedPercent
    var resetAt: Date
    var reportedReset: Date?
    if let clause = resetClause(in: rest) {
      guard let parsed = ClaudeResetTime.parse(clause, now: now) else {
        throw Failure.unrecognizedLine(label)
      }
      resetAt = parsed
      reportedReset = parsed
    } else if used == 0 {
      // Claude Code omits the reset of a window that has not started; an
      // unused window is a fresh one.
      resetAt = now.addingTimeInterval(duration)
    } else {
      throw Failure.unrecognizedLine(label)
    }
    // A reset far outside the window's own length is a misread, not data.
    guard resetAt > now.addingTimeInterval(-24 * 3600),
      resetAt <= now.addingTimeInterval(duration + 24 * 3600) else {
      throw Failure.unrecognizedLine(label)
    }
    // A reset at or before now (Claude Code prints it to the minute, rounded
    // down, and the reading is seconds old) means the window has already
    // reset. Its percentage is no longer live, so show a fresh, unused window.
    if resetAt <= now {
      used = 0
      resetAt = now.addingTimeInterval(duration)
    }

    let window = PressureMath.window(
      provider: .claude,
      speed: kind.isSession ? .fast : .slow,
      usedPercent: used,
      resetAt: resetAt,
      limitWindowSeconds: duration,
      now: now,
      scope: scope,
      visualStyle: style
    )
    return (window, (Int(duration), reportedReset))
  }

  private static func resetClause(in value: String) -> String? {
    guard let match = value.firstMatch(of: /(?i)\bresets?\s+(.+)$/) else {
      return nil
    }
    return String(match.1).trimmingCharacters(in: .whitespaces)
  }
}

/// Parses the reset phrase Claude Code prints after `resets`. Claude Code
/// 2.1.286 formats every `/usage` reset with its date formatter forced to show
/// the date, an hour (minutes only when non-zero), and the time zone, and adds
/// the year whenever the reset is not in the current year:
///
///     Oct 8 at 2pm (America/Guayaquil)          JavaScriptCore (the shipped CLI)
///     Oct 8, 2:30pm (America/Guayaquil)         V8 (Node)
///     Jan 2, 2027 at 9am (America/Guayaquil)    a reset in another year
///     Jan 2, 2027, 9am (America/Guayaquil)      the same, from V8
///     2pm (America/Guayaquil)                   time only: the same formatter's
///                                               form for a reset within a day
///                                               when the date is not forced
///
/// 24-hour times (`14:05`) are accepted too. The zone is the IANA name in
/// parentheses; without one, the system zone the CLI also uses. Anything
/// else, including a date without a time, is rejected rather than guessed.
enum ClaudeResetTime {
  static func parse(_ clause: String, now: Date) -> Date? {
    var text = clause.trimmingCharacters(in: .whitespacesAndNewlines)
    while let last = text.last, ".,;".contains(last) { text.removeLast() }

    var timeZone = TimeZone.current
    if let match = text.firstMatch(of: /\(([^()]+)\)\s*$/) {
      guard let zone = TimeZone(identifier: match.1.trimmingCharacters(in: .whitespaces)) else {
        return nil
      }
      timeZone = zone
      text = String(text[..<match.range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    // [Month day[, year][,] ][at ]hour[:minutes][am|pm]
    guard let match = text.firstMatch(
      of: /(?i)^(?:([a-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?,?\s+)?(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$/
    ) else {
      return nil
    }
    let month = match.1.flatMap { monthNumber(String($0)) }
    if match.1 != nil && month == nil { return nil }
    let day = match.2.flatMap { Int($0) }

    guard let rawHour = Int(match.4) else { return nil }
    let minute = match.5.flatMap { Int($0) } ?? 0
    guard minute < 60 else { return nil }
    let hour: Int
    if let meridiem = match.6?.lowercased() {
      guard (1...12).contains(rawHour) else { return nil }
      hour = rawHour % 12 + (meridiem == "pm" ? 12 : 0)
    } else {
      // A bare hour is ambiguous; a 24-hour time needs its minutes.
      guard match.5 != nil, (0...23).contains(rawHour) else { return nil }
      hour = rawHour
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone

    // During a fall-back hour an ambiguous wall time resolves to its first
    // occurrence, so such a reset can read up to an hour early, at most once a
    // year. The next poll after the real reset corrects it.
    if let month, let day {
      let years: [Int]
      if let year = match.3.flatMap({ Int($0) }) {
        years = [year]
      } else {
        // No year means the current year. The closest of the neighboring
        // years is the current one, except for a poll that straddles
        // midnight on Dec 31, which it also reads correctly.
        let year = calendar.component(.year, from: now)
        years = [year - 1, year, year + 1]
      }
      let candidates = years.compactMap { candidateYear -> Date? in
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
    var components = calendar.dateComponents([.year, .month, .day], from: now)
    components.hour = hour
    components.minute = minute
    guard let today = calendar.date(from: components) else { return nil }
    return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
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
