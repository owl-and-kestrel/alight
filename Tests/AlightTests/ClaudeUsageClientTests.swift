import Foundation
import Testing
@testable import Alight

/// A stand-in `claude` executable. Everything it needs is baked into the
/// script, because the client passes Claude Code only a minimal environment.
private struct FakeClaude {
  let directory: URL
  let executable: URL
  let home: URL
  let work: URL
  let argsLog: URL
  let envLog: URL
  let cwdLog: URL

  init(authStatus: String?, authExit: Int = 0, usage: String = "", usageStderr: String = "",
    usageExit: Int = 0, usageScript: String? = nil) throws {
    directory = FileManager.default.temporaryDirectory.appending(path: "alight-fake-claude-\(UUID().uuidString)")
    let bin = directory.appending(path: "bin")
    home = directory.appending(path: "home")
    work = directory.appending(path: "work")
    for folder in [bin, home] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    executable = bin.appending(path: "claude")
    argsLog = directory.appending(path: "args.log")
    envLog = directory.appending(path: "env.log")
    cwdLog = directory.appending(path: "cwd.log")
    let authFile = directory.appending(path: "auth.json")
    let usageFile = directory.appending(path: "usage.json")
    let stderrFile = directory.appending(path: "usage.stderr")
    try Data((authStatus ?? "").utf8).write(to: authFile)
    try Data(usage.utf8).write(to: usageFile)
    try Data(usageStderr.utf8).write(to: stderrFile)
    let script = """
      #!/bin/sh
      echo "$*" >> '\(argsLog.path)'
      if [ "$1" = "auth" ]; then
        /usr/bin/env > '\(envLog.path)'
        /bin/pwd -P > '\(cwdLog.path)'
        /bin/cat '\(authFile.path)'
        exit \(authExit)
      fi
      \(usageScript ?? "/bin/cat '\(usageFile.path)'; /bin/cat '\(stderrFile.path)' >&2; exit \(usageExit)")
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
  }

  func client(timeout: TimeInterval = 5) -> ClaudeUsageClient {
    ClaudeUsageClient(
      environment: [
        "ALIGHT_CLAUDE_CLI": executable.path,
        "CLAUDE_CODE_OAUTH_TOKEN": "nonsecret-must-not-forward",
        "ANTHROPIC_API_KEY": "nonsecret-must-not-forward",
      ],
      homeDirectory: home,
      workingDirectory: work,
      runner: BoundedProcessRunner(),
      timeout: timeout
    )
  }

  var invocations: [String] {
    ((try? String(contentsOf: argsLog, encoding: .utf8)) ?? "")
      .split(whereSeparator: \.isNewline).map(String.init)
  }

  func cleanUp() {
    try? FileManager.default.removeItem(at: directory)
  }

  static let signedIn = #"{"loggedIn":true,"authMethod":"claude.ai","email":"Person@Example.com","orgId":"org-fixture-1","orgName":"Fixture Org","subscriptionType":"team"}"#

  /// A Team-seat `/usage` text whose session resets 2.5 hours and whose Fable
  /// week resets three days after `now`, printed the way Claude Code does.
  static func usageText(now: Date = Date()) -> String {
    let session = ClaudeUsageParserTests.cliReset(now.addingTimeInterval(9_000), now: now)
    let fable = ClaudeUsageParserTests.cliReset(now.addingTimeInterval(3 * 24 * 3600), now: now)
    return "You are currently using your subscription\n\nCurrent session: 16% used · resets \(session)\nCurrent week (Fable): 4% used · resets \(fable)"
  }
}

@Suite("Claude usage via the Claude Code CLI", .serialized)
struct ClaudeUsageClientTests {
  private var usageOutput: String {
    String(decoding: ClaudeUsageParserTests.commandOutput(result: FakeClaude.usageText()), as: UTF8.self)
  }

  @Test("runs auth status then headless /usage with a minimal environment, and binds the account")
  func happyPath() async throws {
    let fake = try FakeClaude(authStatus: FakeClaude.signedIn, usage: usageOutput)
    defer { fake.cleanUp() }
    let start = Date()
    let result = await fake.client().result()

    #expect(result.ok)
    #expect(result.source == "live")
    #expect(result.windows.count == 2)
    let session = try #require(result.windows.first { $0.scope == nil })
    #expect(session.usedPercent == 16)
    // Printed to the minute, rounded down.
    #expect(abs(session.resetAt.timeIntervalSince(start) - 9_000) < 90)
    #expect(result.windows.contains { $0.scope == .fable && $0.usedPercent == 4 })

    #expect(fake.invocations == [
      "auth status --json",
      "-p /usage --output-format json --no-session-persistence --safe-mode",
    ])

    let identity = try #require(result.observationIdentity)
    #expect(identity.source == ClaudeUsageClient.identitySource)
    #expect(identity.accountPartition.count == 64)
    #expect(identity.limitIdentity == "team")
    #expect(!identity.accountPartition.localizedCaseInsensitiveContains("example"))

    let environment = try String(contentsOf: fake.envLog, encoding: .utf8)
      .split(whereSeparator: \.isNewline)
      .reduce(into: [String: String]()) { result, line in
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        if parts.count == 2 { result[parts[0]] = parts[1] }
      }
    // /bin/sh itself adds PWD, SHLVL and `_`; nothing else may appear.
    let shellAdded: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_"]
    #expect(Set(environment.keys).subtracting(shellAdded) == ["HOME", "USER", "PATH", "TMPDIR", "LANG", "DISABLE_AUTOUPDATER"])
    #expect(environment["HOME"] == fake.home.path)
    #expect(environment["PATH"] == "/usr/bin:/bin:\(fake.executable.deletingLastPathComponent().path)")
    #expect(environment["TMPDIR"] == NSTemporaryDirectory())
    #expect(environment["LANG"] == "en_US.UTF-8")
    #expect(environment["DISABLE_AUTOUPDATER"] == "1")

    let cwd = try String(contentsOf: fake.cwdLog, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    // Foundation drops `/private` when resolving `/var`, so resolve both sides.
    #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == fake.work.resolvingSymlinksInPath().path)
  }

  @Test("a signed-out login asks for sign-in and never runs /usage")
  func signedOut() async throws {
    let fake = try FakeClaude(authStatus: #"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}"#,
      authExit: 1, usage: usageOutput)
    defer { fake.cleanUp() }
    let result = await fake.client().result()
    #expect(!result.ok)
    #expect(result.needsAuth)
    #expect(result.source == ClaudeUsageClient.signedOutSource)
    #expect(result.error == "not signed in to Claude Code")
    #expect(fake.invocations == ["auth status --json"])
  }

  @Test("an unreadable auth status leaves the account unknown but still reads usage")
  func unknownIdentity() async throws {
    let fake = try FakeClaude(authStatus: "not json", usage: usageOutput)
    defer { fake.cleanUp() }
    let result = await fake.client().result()
    #expect(result.ok)
    #expect(result.observationIdentity == nil)
  }

  @Test("a failing CLI reports its own first stderr line")
  func nonzeroExit() async throws {
    let fake = try FakeClaude(authStatus: FakeClaude.signedIn,
      usageStderr: "error: usage service unavailable\nmore detail\n", usageExit: 1)
    defer { fake.cleanUp() }
    let result = await fake.client().result()
    #expect(!result.ok)
    #expect(!result.needsAuth)
    #expect(result.error == "Claude Code exited with status 1: error: usage service unavailable")
    #expect(result.observationIdentity != nil)
  }

  @Test("a CLI too old for a flag Alight passes asks for an update")
  func unknownOption() async throws {
    let fake = try FakeClaude(authStatus: FakeClaude.signedIn,
      usageStderr: "error: unknown option '--safe-mode'\n", usageExit: 1)
    defer { fake.cleanUp() }
    let result = await fake.client().result()
    #expect(result.error == "update Claude Code (error: unknown option '--safe-mode')")
  }

  @Test("a model turn is refused and stops scheduled polling")
  func modelTurn() async throws {
    let output = String(decoding: ClaudeUsageParserTests.commandOutput(result: FakeClaude.usageText(), numTurns: 1), as: UTF8.self)
    let fake = try FakeClaude(authStatus: FakeClaude.signedIn, usage: output)
    defer { fake.cleanUp() }
    let result = await fake.client().result()
    #expect(!result.ok)
    #expect(result.windows.isEmpty)
    #expect(result.source == ClaudeUsageClient.refusedSource)
    var schedule = ClaudePollSchedule()
    schedule.record(result, at: Date())
    #expect(schedule.nextAllowed == .distantFuture)
  }

  @Test("a hung CLI times out")
  func timeout() async throws {
    let fake = try FakeClaude(authStatus: FakeClaude.signedIn, usageScript: "exec /bin/sleep 30")
    defer { fake.cleanUp() }
    let start = ProcessInfo.processInfo.systemUptime
    // The deadline also bounds the fake's `auth status`, so it leaves a loaded
    // host time to start that shell.
    let result = await fake.client(timeout: 2).result()
    #expect(result.error == "Claude Code /usage timed out")
    #expect(ProcessInfo.processInfo.systemUptime - start < 8)
  }

  @Test("a hung auth status fails without also waiting for /usage")
  func authStatusTimeout() async throws {
    let fake = try FakeClaude(authStatus: nil, usage: usageOutput)
    defer { fake.cleanUp() }
    // Rewrite the fake so `auth status` hangs.
    let script = try String(contentsOf: fake.executable, encoding: .utf8)
      .replacingOccurrences(of: "  exit 0\nfi", with: "  exec /bin/sleep 30\nfi")
    try Data(script.utf8).write(to: fake.executable)
    let start = ProcessInfo.processInfo.systemUptime
    let result = await fake.client(timeout: 1).result()
    #expect(result.error == "Claude Code auth status timed out")
    #expect(fake.invocations == ["auth status --json"])
    #expect(ProcessInfo.processInfo.systemUptime - start < 5)
  }

  @Test("huge output is refused")
  func hugeOutput() async throws {
    let fake = try FakeClaude(authStatus: FakeClaude.signedIn, usageScript: "exec /usr/bin/yes x")
    defer { fake.cleanUp() }
    let start = ProcessInfo.processInfo.systemUptime
    let result = await fake.client(timeout: 10).result()
    #expect(result.error == "Claude Code /usage output too large")
    #expect(ProcessInfo.processInfo.systemUptime - start < 8)
  }

  @Test("non-JSON output from a successful exit is rejected")
  func nonJSON() async throws {
    let fake = try FakeClaude(authStatus: FakeClaude.signedIn, usage: "Current session: 16% used · resets in 2h")
    defer { fake.cleanUp() }
    let result = await fake.client().result()
    #expect(!result.ok)
    #expect(result.error == "unexpected Claude Code /usage output")
  }

  @Test("a configured CLI path must be executable")
  func overrideNotExecutable() async {
    let client = ClaudeUsageClient(
      environment: ["ALIGHT_CLAUDE_CLI": "/nonexistent/alight-test/claude"],
      homeDirectory: URL(fileURLWithPath: "/nonexistent/home"),
      workingDirectory: FileManager.default.temporaryDirectory,
      runner: BoundedProcessRunner()
    )
    let result = await client.result()
    #expect(result.error == "ALIGHT_CLAUDE_CLI is not an executable file")
  }

  @Test("CLI resolution: override, standard install locations, then Node version managers")
  func resolution() {
    let home = URL(fileURLWithPath: "/nonsecret/home", isDirectory: true)
    let nvm = "/nonsecret/home/.nvm/versions/node"
    func resolve(_ environment: [String: String], _ executable: Set<String>) -> ClaudeUsageClient.ExecutableResolution {
      ClaudeUsageClient.resolveExecutable(
        environment: environment,
        homeDirectory: home,
        isExecutable: { executable.contains($0) },
        listDirectory: { $0 == nvm ? ["v9.0.0", "v22.22.0", "v20.1.0"] : nil }
      )
    }
    let all: Set<String> = ["/nonsecret/home/.local/bin/claude", "/opt/homebrew/bin/claude",
      "/usr/local/bin/claude", "/nonsecret/home/.claude/local/claude", "/custom/claude"]
    #expect(resolve(["ALIGHT_CLAUDE_CLI": "/custom/claude"], all) == .found("/custom/claude"))
    #expect(resolve(["ALIGHT_CLAUDE_CLI": "/custom/missing"], all) == .overrideNotExecutable)
    #expect(resolve(["ALIGHT_CLAUDE_CLI": "relative/claude"], ["relative/claude"]) == .overrideNotExecutable)
    #expect(resolve([:], all) == .found("/nonsecret/home/.local/bin/claude"))
    #expect(resolve([:], ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]) == .found("/opt/homebrew/bin/claude"))
    #expect(resolve([:], ["/usr/local/bin/claude", "/nonsecret/home/.claude/local/claude"]) == .found("/usr/local/bin/claude"))
    #expect(resolve([:], ["/nonsecret/home/.claude/local/claude", "/nonsecret/home/.volta/bin/claude"])
      == .found("/nonsecret/home/.claude/local/claude"))
    #expect(resolve([:], ["/nonsecret/home/.volta/bin/claude", "/nonsecret/home/.bun/bin/claude"])
      == .found("/nonsecret/home/.volta/bin/claude"))
    #expect(resolve([:], ["/nonsecret/home/.bun/bin/claude", "\(nvm)/v22.22.0/bin/claude"])
      == .found("/nonsecret/home/.bun/bin/claude"))
    // The newest nvm Node wins, compared numerically.
    #expect(resolve([:], ["\(nvm)/v9.0.0/bin/claude", "\(nvm)/v22.22.0/bin/claude", "\(nvm)/v20.1.0/bin/claude"])
      == .found("\(nvm)/v22.22.0/bin/claude"))
    #expect(resolve([:], []) == .notFound)
  }

  @Test("/usage arguments are the local command, not a prompt")
  func arguments() {
    #expect(ClaudeUsageClient.usageArguments == ["-p", "/usage", "--output-format", "json", "--no-session-persistence", "--safe-mode"])
    #expect(ClaudeUsageClient.authStatusArguments == ["auth", "status", "--json"])
  }

  @Test("account identity is a stable digest of email and organization, never the raw email")
  func identityDigest() throws {
    let a = try #require(ClaudeAuthStatus.observationIdentity(email: "Person@Example.com", orgId: "org-1", subscriptionType: "Team"))
    let again = try #require(ClaudeAuthStatus.observationIdentity(email: " person@example.com ", orgId: "org-1", subscriptionType: "team"))
    let otherOrg = try #require(ClaudeAuthStatus.observationIdentity(email: "person@example.com", orgId: "org-2", subscriptionType: "team"))
    let otherPerson = try #require(ClaudeAuthStatus.observationIdentity(email: "someone@example.com", orgId: "org-1", subscriptionType: "team"))
    #expect(a == again)
    #expect(a.accountPartition != otherOrg.accountPartition)
    #expect(a.accountPartition != otherPerson.accountPartition)
    #expect(a.limitIdentity == "team")
    #expect(!a.accountPartition.contains("person"))
    #expect(ClaudeAuthStatus.observationIdentity(email: nil, orgId: "org-1", subscriptionType: "team") == nil)
    #expect(ClaudeAuthStatus.observationIdentity(email: "  ", orgId: "org-1", subscriptionType: "team") == nil)

    #expect(ClaudeAuthStatus.parse(Data(#"{"loggedIn":false}"#.utf8)) == ClaudeAuthStatus(loggedIn: false, identity: nil))
    #expect(ClaudeAuthStatus.parse(Data("garbage".utf8)) == nil)
    #expect(ClaudeAuthStatus.parse(Data(#"{"loggedIn":true}"#.utf8))?.identity == nil)
  }

  @Test("Claude polls: every three minutes on success, backing off to fifteen on failure")
  func pollSchedule() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let ok = ProviderResult(provider: .claude, ok: true, source: "live", error: nil, windows: [])
    let failure = ProviderResult.failure(.claude, source: "error", error: "x")
    // /usage itself asked for sign-in: both commands ran, so this backs off.
    let usageAuth = ProviderResult.failure(.claude, source: "error", error: "x", needsAuth: true)

    var schedule = ClaudePollSchedule()
    #expect(schedule.isDue(at: now))
    schedule.record(failure, at: now)
    schedule.record(ok, at: now)
    #expect(schedule.backoff == 0)
    #expect(schedule.nextAllowed == now.addingTimeInterval(180))
    #expect(!schedule.isDue(at: now.addingTimeInterval(179)))
    #expect(schedule.isDue(at: now.addingTimeInterval(180)))

    var waits: [TimeInterval] = []
    for result in [failure, usageAuth, failure, failure, failure] {
      schedule.record(result, at: now)
      waits.append(schedule.nextAllowed.timeIntervalSince(now))
    }
    #expect(waits == [180, 360, 720, 900, 900])
  }

  @Test("a signed-out CLI is rechecked every minute without backing off")
  func signedOutSchedule() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let signedOut = ProviderResult.failure(.claude, source: ClaudeUsageClient.signedOutSource,
      error: "not signed in to Claude Code", needsAuth: true)
    var schedule = ClaudePollSchedule()
    schedule.record(.failure(.claude, source: "error", error: "x"), at: now)
    for _ in 0..<4 {
      schedule.record(signedOut, at: now)
      #expect(schedule.backoff == 0)
      #expect(schedule.nextAllowed == now.addingTimeInterval(60))
    }
  }

  @Test("deferred cycles keep Sign in to Claude and the latest reason between polls")
  func deferredKeepsSignIn() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var schedule = ClaudePollSchedule()
    schedule.record(.failure(.claude, source: ClaudeUsageClient.signedOutSource,
      error: "not signed in to Claude Code", needsAuth: true), at: now)

    let deferred = schedule.deferredResult(now: now.addingTimeInterval(30))
    #expect(deferred.source == "deferred")
    #expect(deferred.needsAuth)
    #expect(deferred.error == "not signed in to Claude Code · retry in 30s")
    #expect(deferred.observationIdentity == nil)

    // With no cached reading to show, the store's reconcile keeps it as is,
    // so the menu still offers Sign in to Claude….
    var cache = UsageResultCache(persistenceURL: nil, antigravitySourceIdentity: "test")
    let shown = cache.reconcile(deferred, now: now.addingTimeInterval(30))
    #expect(shown.needsAuth)
    #expect(shown.error == "not signed in to Claude Code · retry in 30s")
  }

  @Test("deferred cycles carry the account, and a failure's actionable reason")
  func deferredCarriesState() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let identity = try #require(ClaudeAuthStatus.observationIdentity(email: "person@example.com", orgId: "org-1", subscriptionType: "max"))
    var schedule = ClaudePollSchedule()
    #expect(schedule.deferredResult(now: now).observationIdentity == nil)

    var ok = ProviderResult(provider: .claude, ok: true, source: "live", error: nil, windows: [])
    ok.observationIdentity = identity
    schedule.record(ok, at: now)
    let afterSuccess = schedule.deferredResult(now: now.addingTimeInterval(60))
    #expect(afterSuccess.error == "next live poll in 2m")
    #expect(afterSuccess.observationIdentity == identity)
    #expect(!afterSuccess.needsAuth)

    schedule.record(.failure(.claude, source: "error",
      error: "Claude Code CLI not found (install it or set ALIGHT_CLAUDE_CLI)"), at: now)
    #expect(schedule.deferredResult(now: now.addingTimeInterval(60)).error
      == "Claude Code CLI not found (install it or set ALIGHT_CLAUDE_CLI) · retry in 2m")

    let refusal = ClaudeUsageParser.Failure.modelTurn.message
    schedule.record(.failure(.claude, source: ClaudeUsageClient.refusedSource, error: refusal), at: now)
    #expect(schedule.deferredResult(now: now.addingTimeInterval(3600)).error == refusal)
    #expect(refusal.contains("Update Claude Code"))
  }
}
