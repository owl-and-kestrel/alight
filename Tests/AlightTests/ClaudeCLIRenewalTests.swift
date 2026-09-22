import Foundation
import Testing
@testable import Alight

@Suite("Claude CLI renewal")
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
