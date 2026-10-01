import Foundation
import Darwin
import Testing
@testable import Alight

@Suite("Claude CLI renewal", .serialized)
struct ClaudeCLIRenewalTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let home = URL(fileURLWithPath: "/nonsecret/test-home", isDirectory: true)

  private func credential(expiresIn: TimeInterval?, refresh: Bool) -> ClaudeCredential {
    ClaudeCredential(
      accessToken: "nonsecret",
      expiresAt: expiresIn.map { now.addingTimeInterval($0) },
      hasRefreshToken: refresh
    )
  }

  @Test("renews only inside the CLI's pre-expiry window or after expiry")
  func renewalWindow() {
    #expect(ClaudeCLIRenewal.shouldRenew(credential(expiresIn: 3600, refresh: true), now: now) == false)
    #expect(ClaudeCLIRenewal.shouldRenew(credential(expiresIn: 5 * 60, refresh: true), now: now) == false)
    #expect(ClaudeCLIRenewal.shouldRenew(credential(expiresIn: 4 * 60, refresh: true), now: now))
    #expect(ClaudeCLIRenewal.shouldRenew(credential(expiresIn: -3600, refresh: true), now: now))
  }

  @Test("never renews without a refresh token or expiry")
  func renewalRequiresRefreshableKeychainLogin() {
    #expect(ClaudeCLIRenewal.shouldRenew(credential(expiresIn: -60, refresh: false), now: now) == false)
    #expect(ClaudeCLIRenewal.shouldRenew(credential(expiresIn: nil, refresh: true), now: now) == false)
  }

  @Test("polls are pulled forward into the renewal window")
  func pollSchedulingTracksExpiry() {
    let expiresAt = now.addingTimeInterval(3600)
    let renewal = ClaudeCLIRenewal.renewalTime(for: expiresAt)
    // Inside the CLI's five-minute window, with slack for the one-minute loop.
    #expect(expiresAt.timeIntervalSince(renewal) < 5 * 60)
    #expect(expiresAt.timeIntervalSince(renewal) > 3 * 60)

    let scheduled = now.addingTimeInterval(300)
    #expect(UsageStore.claudePollTime(scheduled: scheduled, credentialExpiresAt: nil, now: now) == scheduled)
    // A distant expiry never delays the normal cadence.
    #expect(UsageStore.claudePollTime(scheduled: scheduled, credentialExpiresAt: expiresAt, now: now) == scheduled)
    // An imminent expiry pulls the poll forward to the renewal moment.
    let soon = now.addingTimeInterval(6 * 60)
    #expect(UsageStore.claudePollTime(scheduled: scheduled, credentialExpiresAt: soon, now: now)
      == ClaudeCLIRenewal.renewalTime(for: soon))
    // An expiry already inside (or past) the window keeps the scheduled time.
    let past = now.addingTimeInterval(60)
    #expect(UsageStore.claudePollTime(scheduled: scheduled, credentialExpiresAt: past, now: now) == scheduled)
  }

  @Test("server Retry-After outranks an earlier credential renewal window")
  func retryAfterOutranksExpiry() {
    let scheduled = now.addingTimeInterval(900)
    #expect(UsageStore.claudePollTime(scheduled: scheduled,
      credentialExpiresAt: now.addingTimeInterval(360), now: now,
      retryAfterSeconds: 900) == scheduled)
    #expect(UsageStore.claudePollTime(scheduled: now.addingTimeInterval(300),
      credentialExpiresAt: now.addingTimeInterval(360), now: now,
      retryAfterSeconds: 900) == scheduled)
  }

  @Test("a rejected refreshable login exposes sign in after unsuccessful renewal")
  func failedRenewalExposesSignIn() {
    let result = ClaudeUsageClient.rejectedCredentialResult(credential(expiresIn: 3600, refresh: true))
    #expect(result.needsAuth)
    #expect(!result.ok)
    #expect(result.error?.contains("sign in") == true)
    #expect(result.credentialExpiresAt == now.addingTimeInterval(3600))
  }

  @Test("login shell discovery has a bounded asynchronous deadline")
  func boundedDiscovery() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "alight-discovery-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let shell = directory.appending(path: "fake-shell")
    try Data("#!/bin/sh\nexec /bin/sleep 2\n".utf8).write(to: shell)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
    let start = Date()
    let path = await ClaudeCLIRenewal.loginShellLookup(environment: ["SHELL": shell.path], timeout: 0.05)
    #expect(path == nil)
    #expect(Date().timeIntervalSince(start) < 1)
  }

  private func discoveryFixture(_ script: String) throws -> (URL, URL, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "alight-process-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let shell = directory.appending(path: "fake-shell")
    try Data(("#!/bin/sh\n" + script).utf8).write(to: shell)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
    return (directory, shell, directory.appending(path: "pids"))
  }

  private func recordedPIDs(_ file: URL) throws -> [pid_t] {
    try String(contentsOf: file, encoding: .utf8).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
  }

  @Test("normal short discovery preserves output and reaps its child")
  func successfulDiscoveryCleanup() async throws {
    let (directory, shell, pids) = try discoveryFixture("echo $$ > \"$ALIGHT_TEST_PID_FILE\"\nprintf '/nonsecret/claude\\n'\n")
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = await ClaudeCLIRenewal.loginShellLookup(environment: ["SHELL": shell.path,
      "ALIGHT_TEST_PID_FILE": pids.path], timeout: 1)
    #expect(path == "/nonsecret/claude")
    let pid = try #require(recordedPIDs(pids).first)
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
  }

  @Test("timeout kills and reaps a TERM-resistant discovery child before returning")
  func resistantDiscoveryCleanup() async throws {
    let (directory, shell, pids) = try discoveryFixture("trap '' TERM\necho $$ > \"$ALIGHT_TEST_PID_FILE\"\nexec /bin/sleep 30\n")
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = ProcessInfo.processInfo.systemUptime
    let path = await ClaudeCLIRenewal.loginShellLookup(environment: ["SHELL": shell.path,
      "ALIGHT_TEST_PID_FILE": pids.path], timeout: 0.5)
    #expect(path == nil)
    #expect(ProcessInfo.processInfo.systemUptime - start < 2)
    let pid = try #require(recordedPIDs(pids).first)
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
  }

  @Test("an exited shell's stdout-holding descendant is cleaned up before completion")
  func descendantDiscoveryCleanup() async throws {
    let (directory, shell, pids) = try discoveryFixture("trap '' TERM\n/bin/sleep 30 &\necho $$ $! > \"$ALIGHT_TEST_PID_FILE\"\nprintf '/nonsecret/claude\\n'\nexit 0\n")
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = ProcessInfo.processInfo.systemUptime
    let path = await ClaudeCLIRenewal.loginShellLookup(environment: ["SHELL": shell.path,
      "ALIGHT_TEST_PID_FILE": pids.path], timeout: 1)
    #expect(path == "/nonsecret/claude")
    #expect(ProcessInfo.processInfo.systemUptime - start < 1)
    let processes = try recordedPIDs(pids)
    #expect(processes.count == 2)
    for pid in processes { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
  }

  @Test("oversized discovery output is capped and its writer is reaped without waiting for the deadline")
  func oversizedDiscoveryCleanup() async throws {
    let (directory, shell, pids) = try discoveryFixture("trap '' TERM\necho $$ > \"$ALIGHT_TEST_PID_FILE\"\nexec /usr/bin/yes x\n")
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = ProcessInfo.processInfo.systemUptime
    let path = await ClaudeCLIRenewal.loginShellLookup(environment: ["SHELL": shell.path,
      "ALIGHT_TEST_PID_FILE": pids.path], timeout: 2)
    #expect(path == nil)
    #expect(ProcessInfo.processInfo.systemUptime - start < 1)
    let pid = try #require(recordedPIDs(pids).first)
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
    // Discovery uses a bounded pipe; no stdout file can grow or be unlinked
    // while a signal-resistant writer continues producing bytes.
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["fake-shell", "pids"])
  }

  @Test("an escaped stdout holder cannot block discovery; fixture cleans its own session")
  func escapedStdoutDiscovery() async throws {
    let script = """
      /usr/bin/python3 -c 'import os,time; os.setsid(); open(os.environ["ALIGHT_TEST_ESCAPE_FILE"],"w").write(str(os.getpid())); time.sleep(30)' &
      echo $$ $! > "$ALIGHT_TEST_PID_FILE"
      while [ ! -s "$ALIGHT_TEST_ESCAPE_FILE" ]; do /bin/sleep 0.01; done
      printf '/nonsecret/claude\\n'
      exit 0
      """
    let (directory, shell, pids) = try discoveryFixture(script)
    let escapedFile = directory.appending(path: "escaped-pid")
    var needsCleanup = true
    // Only this fixture's recorded child is signaled. The product never
    // inventories or kills a process outside its invocation's owned group.
    defer {
      if needsCleanup, let processes = try? recordedPIDs(pids), processes.count == 2 { _ = kill(processes[1], SIGKILL) }
      try? FileManager.default.removeItem(at: directory)
    }
    let start = ProcessInfo.processInfo.systemUptime
    let path = await ClaudeCLIRenewal.loginShellLookup(environment: ["SHELL": shell.path,
      "ALIGHT_TEST_PID_FILE": pids.path, "ALIGHT_TEST_ESCAPE_FILE": escapedFile.path], timeout: 2)
    #expect(path == nil) // Incomplete cleanup/output cannot become a successful lookup.
    #expect(ProcessInfo.processInfo.systemUptime - start < 2)
    let processes = try recordedPIDs(pids)
    #expect(processes.count == 2)
    let escaped = try #require(recordedPIDs(escapedFile).first)
    #expect(escaped == processes[1])
    #expect(kill(processes[0], 0) == -1 && errno == ESRCH)
    #expect(kill(escaped, 0) == 0) // It did escape the product-owned process group.
    #expect(kill(escaped, SIGKILL) == 0)
    let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 1
    while kill(escaped, 0) == 0 && ProcessInfo.processInfo.systemUptime < cleanupDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let cleaned = kill(escaped, 0) == -1 && errno == ESRCH
    #expect(cleaned)
    needsCleanup = !cleaned
    let nextShell = directory.appending(path: "next-shell")
    try Data("#!/bin/sh\nprintf '/nonsecret/after-escape\\n'\n".utf8).write(to: nextShell)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nextShell.path)
    let next = await ClaudeCLIRenewal.loginShellLookup(environment: ["SHELL": nextShell.path], timeout: 1)
    #expect(next == "/nonsecret/after-escape")
  }

  @Test("an expired refreshable login is a renewal in progress, not a sign-out")
  func expiredLoginGrace() {
    let justExpired = credential(expiresIn: -30, refresh: true)
    let renewing = ClaudeUsageClient.expiredResult(justExpired, expiresAt: justExpired.expiresAt!, now: now)
    #expect(renewing.needsAuth == false)
    #expect(renewing.source == "renewing")
    #expect(renewing.retryAfterSeconds == ClaudeCLIRenewal.minimumAttemptInterval)
    #expect(renewing.credentialExpiresAt == justExpired.expiresAt)

    let longExpired = credential(expiresIn: -ClaudeUsageClient.renewalGrace - 1, refresh: true)
    let lapsed = ClaudeUsageClient.expiredResult(longExpired, expiresAt: longExpired.expiresAt!, now: now)
    #expect(lapsed.needsAuth)
    #expect(lapsed.source == "expired")

    let noRefresh = credential(expiresIn: -30, refresh: false)
    let unrecoverable = ClaudeUsageClient.expiredResult(noRefresh, expiresAt: noRefresh.expiresAt!, now: now)
    #expect(unrecoverable.needsAuth)
    #expect(unrecoverable.error?.contains("sign in") == true)
  }

  @Test("renewal runs no inference request")
  func renewalArguments() {
    #expect(ClaudeCLIRenewal.arguments.first == "mcp")
    #expect(!ClaudeCLIRenewal.arguments.contains("-p"))
    #expect(!ClaudeCLIRenewal.arguments.contains("--print"))
  }

  @Test("environment drops overrides that bypass the Keychain login")
  func renewalEnvironment() {
    let filtered = ClaudeCLIRenewal.renewalEnvironment(from: [
      "HOME": "/nonsecret",
      "PATH": "/usr/bin",
      "CLAUDE_CODE_OAUTH_TOKEN": "x",
      "CLAUDE_CODE_ENTRYPOINT": "x",
      "ANTHROPIC_API_KEY": "x",
      "ANTHROPIC_BASE_URL": "x",
      "CLAUDECODE": "1",
    ])
    #expect(filtered == ["HOME": "/nonsecret", "PATH": "/usr/bin"])
  }

  @Test("explicit CLI override wins and must be executable")
  func executableOverride() {
    let resolve = { (executable: Set<String>) in
      ClaudeCLIRenewal.resolveExecutable(
        environment: ["ALIGHT_CLAUDE_CLI": "/custom/claude"],
        homeDirectory: home,
        isExecutable: { executable.contains($0) },
        listDirectory: { _ in nil },
        loginShellLookup: { Issue.record("shell should not run"); return nil }
      )
    }
    #expect(resolve(["/custom/claude", "/usr/local/bin/claude"]) == "/custom/claude")
    #expect(resolve(["/usr/local/bin/claude"]) == nil)
  }

  @Test("prefers the native install, then the newest nvm node")
  func executableCandidates() {
    let nvm = "/nonsecret/test-home/.nvm/versions/node"
    let resolve = { (executable: Set<String>) in
      ClaudeCLIRenewal.resolveExecutable(
        environment: [:],
        homeDirectory: home,
        isExecutable: { executable.contains($0) },
        listDirectory: { path in path == nvm ? ["v9.0.0", "v22.22.0", "v20.1.0"] : nil },
        loginShellLookup: { nil }
      )
    }
    #expect(resolve(["/nonsecret/test-home/.local/bin/claude", "\(nvm)/v22.22.0/bin/claude"])
      == "/nonsecret/test-home/.local/bin/claude")
    #expect(resolve(["\(nvm)/v9.0.0/bin/claude", "\(nvm)/v22.22.0/bin/claude"])
      == "\(nvm)/v22.22.0/bin/claude")
  }

  @Test("falls back to an absolute login-shell path")
  func executableLoginShellFallback() {
    let resolve = { (found: String?) in
      ClaudeCLIRenewal.resolveExecutable(
        environment: [:],
        homeDirectory: home,
        isExecutable: { $0 == "/elsewhere/claude" },
        listDirectory: { _ in nil },
        loginShellLookup: { found }
      )
    }
    #expect(resolve("/elsewhere/claude") == "/elsewhere/claude")
    #expect(resolve("claude") == nil)
    #expect(resolve(nil) == nil)
  }
}
