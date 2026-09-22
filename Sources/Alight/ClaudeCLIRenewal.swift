import Foundation
import OSLog

/// Keeps the shared `Claude Code-credentials` Keychain login fresh by briefly
/// running the user's own `claude` CLI, which renews its access token itself.
///
/// Claude Code access tokens last about eight hours and are renewed only when
/// the standalone CLI runs inside its five-minute pre-expiry window. The Claude
/// desktop app does not use this Keychain item, so a desktop-first user's CLI
/// login silently lapses and the refresh token is eventually dropped.
///
/// Alight stays read-only: the CLI owns refresh and Keychain write-back. The
/// renewal command sends no inference request. `claude mcp get <name>` loads
/// claude.ai connector configuration, which renews the OAuth token first; an
/// unknown server name then exits without starting any configured MCP server.
actor ClaudeCLIRenewal {
  static let shared = ClaudeCLIRenewal()

  /// Claude Code refreshes only when its token expires within five minutes.
  /// Stay inside that window so the run is never a no-op.
  static let renewalLead: TimeInterval = 4 * 60
  /// Matches the store's credential retry cadence so an expired login is
  /// retried every poll during the renewal grace period.
  static let minimumAttemptInterval: TimeInterval = 60
  static let timeout: TimeInterval = 30
  static let arguments = ["mcp", "get", "__alight_token_renewal__"]

  private static let logger = Logger(subsystem: "com.owlandkestrel.alight", category: "usage")
  private var lastAttempt: Date?

  /// Only a Keychain login that still carries a refresh token can be renewed.
  static func shouldRenew(_ credential: ClaudeCredential, now: Date) -> Bool {
    guard credential.hasRefreshToken, let expiresAt = credential.expiresAt else {
      return false
    }
    return expiresAt.timeIntervalSince(now) <= renewalLead
  }

  /// The moment a poll should run so the CLI renewal lands inside its
  /// pre-expiry window. Polls happen on a one-minute loop, so aim a little
  /// after the window opens rather than exactly at its edge.
  static func renewalTime(for expiresAt: Date) -> Date {
    expiresAt.addingTimeInterval(-renewalLead + 15)
  }

  /// Runs the CLI at most once per `minimumAttemptInterval`. Returns whether a
  /// run completed; the caller re-reads the Keychain to learn the outcome.
  /// `force` skips the interval for a single retry after a rejected token.
  func renew(now: Date = Date(), force: Bool = false) async -> Bool {
    if !force, let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.minimumAttemptInterval {
      return false
    }
    lastAttempt = now

    let environment = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser
    guard let executable = Self.resolveExecutable(
      environment: environment,
      homeDirectory: home,
      isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
      listDirectory: { try? FileManager.default.contentsOfDirectory(atPath: $0) },
      loginShellLookup: { Self.loginShellLookup(environment: environment) }
    ) else {
      Self.logger.info("Claude renewal skipped reason=cli_not_found")
      return false
    }

    let status = await Self.run(
      executable: executable,
      environment: Self.renewalEnvironment(from: environment)
    )
    Self.logger.info("Claude renewal ran status=\(status.map(String.init) ?? "timeout", privacy: .public)")
    return status != nil
  }

  // MARK: - Pure helpers

  /// Explicit override first, then common install locations, then the login
  /// shell. A GUI login item does not inherit the user's interactive PATH.
  static func resolveExecutable(
    environment: [String: String],
    homeDirectory: URL,
    isExecutable: (String) -> Bool,
    listDirectory: (String) -> [String]?,
    loginShellLookup: () -> String?
  ) -> String? {
    if let override = environment["ALIGHT_CLAUDE_CLI"], !override.isEmpty {
      let path = (override as NSString).expandingTildeInPath
      return isExecutable(path) ? path : nil
    }

    let home = homeDirectory.path
    var candidates = [
      "\(home)/.local/bin/claude",
      "\(home)/.claude/local/claude",
      "/opt/homebrew/bin/claude",
      "/usr/local/bin/claude",
      "\(home)/.volta/bin/claude",
      "\(home)/.bun/bin/claude",
    ]
    let nvmVersions = "\(home)/.nvm/versions/node"
    let versions = (listDirectory(nvmVersions) ?? [])
      .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    candidates += versions.map { "\(nvmVersions)/\($0)/bin/claude" }

    if let found = candidates.first(where: isExecutable) {
      return found
    }
    if let found = loginShellLookup(), found.hasPrefix("/"), isExecutable(found) {
      return found
    }
    return nil
  }

  /// Drop variables that would make the CLI bypass the Keychain login (an
  /// explicit OAuth token or API key takes precedence and disables claude.ai
  /// connectors) or talk to a different endpoint.
  static func renewalEnvironment(from environment: [String: String]) -> [String: String] {
    environment.filter { key, _ in
      !(key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("ANTHROPIC_") || key == "CLAUDECODE")
    }
  }

  // MARK: - Process

  private static func loginShellLookup(environment: [String: String]) -> String? {
    let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-lc", "command -v claude"]
    process.standardInput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let stdout = Pipe()
    process.standardOutput = stdout
    do {
      try process.run()
    } catch {
      return nil
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      return nil
    }
    let path = String(decoding: data, as: UTF8.self)
      .split(whereSeparator: \.isNewline).last
      .map { $0.trimmingCharacters(in: .whitespaces) }
    return path?.isEmpty == false ? path : nil
  }

  /// Returns the exit status, or nil when the CLI could not start or timed out.
  /// The unknown-server lookup exits non-zero by design, so status is only
  /// logged; the refreshed Keychain item is the real signal.
  private static func run(executable: String, environment: [String: String]) async -> Int32? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    // An empty working directory keeps project `.mcp.json` files out of the run.
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    return await withCheckedContinuation { continuation in
      let finished = Finished()
      process.terminationHandler = { process in
        if finished.claim() {
          continuation.resume(returning: process.terminationReason == .exit ? process.terminationStatus : nil)
        }
      }
      do {
        try process.run()
      } catch {
        if finished.claim() {
          continuation.resume(returning: nil)
        }
        return
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        if finished.claim() {
          process.terminate()
          continuation.resume(returning: nil)
        }
      }
    }
  }

  private final class Finished: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if done {
        return false
      }
      done = true
      return true
    }
  }
}
