import Foundation
import Darwin
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
    var executable = Self.resolveExecutable(
      environment: environment,
      homeDirectory: home,
      isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
      listDirectory: { try? FileManager.default.contentsOfDirectory(atPath: $0) },
      loginShellLookup: { nil }
    )
    if executable == nil, environment["ALIGHT_CLAUDE_CLI"].map({ $0.isEmpty }) ?? true,
       let discovered = await Self.loginShellLookup(environment: environment),
       discovered.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: discovered) {
      executable = discovered
    }
    guard let executable else {
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

  static func loginShellLookup(environment: [String: String], timeout: TimeInterval = 5) async -> String? {
    let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    let directory = FileManager.default.temporaryDirectory.appending(path: "alight-cli-discovery-\(UUID().uuidString)")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch { return nil }
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = await OwnedProcessRunner.shared.execute(executable: shell,
      arguments: ["-lc", "command -v claude"], environment: renewalEnvironment(from: environment),
      directory: directory.path, timeout: timeout, outputLimit: 4096)
    guard result.status == 0 else { return nil }
    let path = String(decoding: result.output, as: UTF8.self)
      .split(whereSeparator: \.isNewline).last
      .map { $0.trimmingCharacters(in: .whitespaces) }
    return path?.isEmpty == false ? path : nil
  }

  /// Returns the exit status, or nil when the CLI could not start or timed out.
  /// The unknown-server lookup exits non-zero by design, so status is only
  /// logged; the refreshed Keychain item is the real signal.
  private static func run(executable: String, environment: [String: String]) async -> Int32? {
    await OwnedProcessRunner.shared.execute(executable: executable, arguments: arguments,
      environment: environment, directory: FileManager.default.temporaryDirectory.path,
      timeout: timeout, outputLimit: nil).status
  }

  /// Spawn each invocation in its own process group. A bounded pipe replaces
  /// file-backed discovery output. Deadline/overflow initiates TERM, then KILL;
  /// the direct child is observed and reaped before the caller can retry.
  private final class OwnedProcessRunner: @unchecked Sendable {
    static let shared = OwnedProcessRunner()
    private let queue = DispatchQueue(label: "com.owlandkestrel.alight.cli-process")

    struct Result: Sendable {
      let status: Int32?
      let output: Data
    }

    func execute(executable: String, arguments: [String], environment: [String: String],
      directory: String, timeout: TimeInterval, outputLimit: Int?) async -> Result {
      await withCheckedContinuation { continuation in
        queue.async {
          continuation.resume(returning: self.executeSync(executable: executable, arguments: arguments,
            environment: environment, directory: directory, timeout: timeout, outputLimit: outputLimit))
        }
      }
    }

    private func executeSync(executable: String, arguments: [String], environment: [String: String],
      directory: String, timeout: TimeInterval, outputLimit: Int?) -> Result {
      let failed = Result(status: nil, output: Data())
      guard timeout.isFinite, timeout > 0 else { return failed }
      let null = open("/dev/null", O_RDWR | O_CLOEXEC)
      guard null >= 0 else { return failed }
      defer { close(null) }
      var descriptors: [Int32] = [-1, -1]
      if outputLimit != nil {
        guard pipe(&descriptors) == 0 else { return failed }
        guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0 else {
          close(descriptors[0]); close(descriptors[1]); return failed
        }
        _ = fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptors[1], F_SETFD, FD_CLOEXEC)
      }
      defer {
        if descriptors[0] >= 0 { close(descriptors[0]) }
        if descriptors[1] >= 0 { close(descriptors[1]) }
      }
      var actions: posix_spawn_file_actions_t?
      var attributes: posix_spawnattr_t?
      guard posix_spawn_file_actions_init(&actions) == 0 else { return failed }
      defer { posix_spawn_file_actions_destroy(&actions) }
      guard posix_spawnattr_init(&attributes) == 0 else { return failed }
      defer { posix_spawnattr_destroy(&attributes) }
      guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
        posix_spawnattr_setpgroup(&attributes, 0) == 0,
        posix_spawn_file_actions_adddup2(&actions, null, STDIN_FILENO) == 0,
        posix_spawn_file_actions_adddup2(&actions, null, STDERR_FILENO) == 0,
        posix_spawn_file_actions_adddup2(&actions, outputLimit == nil ? null : descriptors[1], STDOUT_FILENO) == 0,
        posix_spawn_file_actions_addchdir_np(&actions, directory) == 0 else { return failed }
      let argv = ([executable] + arguments).map { strdup($0) } + [nil]
      let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
      defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
      var pid: pid_t = 0
      let spawned = argv.withUnsafeBufferPointer { argv in
        envp.withUnsafeBufferPointer { envp in
          posix_spawn(&pid, executable, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
        }
      }
      guard spawned == 0 else { return failed }
      if descriptors[1] >= 0 { close(descriptors[1]); descriptors[1] = -1 }
      let deadline = ProcessInfo.processInfo.systemUptime + timeout
      var stoppingAt: TimeInterval?
      var exitedAt: TimeInterval?
      var killed = false
      var output = Data()
      var outputClosed = outputLimit == nil
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let now = ProcessInfo.processInfo.systemUptime
        if let limit = outputLimit, !outputClosed {
          // Read only enough to detect overflow. The kernel pipe is bounded;
          // an over-producing child is terminated instead of growing a file.
          let count = read(descriptors[0], &buffer,
            stoppingAt == nil ? min(buffer.count, limit - output.count + 1) : buffer.count)
          if count > 0 {
            if stoppingAt == nil && output.count + count > limit { stoppingAt = now }
            else if stoppingAt == nil { output.append(contentsOf: buffer.prefix(count)) }
          } else if count == 0 { outputClosed = true }
          else if count < 0 && errno != EAGAIN && errno != EINTR { stoppingAt = now }
        }
        if stoppingAt == nil && now >= deadline { stoppingAt = now }
        if let stoppingAt {
          if !killed && now - stoppingAt >= 0.1 {
            _ = kill(-pid, SIGKILL)
            killed = true
          } else if !killed { _ = kill(-pid, SIGTERM) }
        }
        // WNOWAIT keeps the child PID reserved until its group has received
        // cleanup, avoiding a signal to a recycled process-group identifier.
        var info = siginfo_t()
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid {
          _ = kill(-pid, SIGKILL) // Also clean up inherited shell descendants.
          // Give owned writers a short drain after cleanup. A shell-startup
          // descendant may create its own session and retain stdout outside
          // our group; close that pipe and fail rather than wait indefinitely
          // or signal a process outside this invocation's owned group.
          if exitedAt == nil { exitedAt = now }
          if !outputClosed {
            if now - exitedAt! < 0.1 { usleep(5_000); continue }
            stoppingAt = stoppingAt ?? now
            close(descriptors[0]); descriptors[0] = -1
            outputClosed = true
          }
          var status: Int32 = 0
          var reaped: pid_t
          repeat { reaped = waitpid(pid, &status, 0) } while reaped < 0 && errno == EINTR
          guard reaped == pid else { return failed }
          return Result(status: stoppingAt == nil && status & 0x7f == 0 ? (status >> 8) & 0xff : nil,
            output: output)
        }
        usleep(5_000)
      }
    }
  }
}
