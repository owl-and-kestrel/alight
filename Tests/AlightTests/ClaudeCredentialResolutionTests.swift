import Foundation
import Testing
@testable import Alight

@Suite("Claude credential resolution")
struct ClaudeCredentialResolutionTests {
  private let home = URL(fileURLWithPath: "/nonsecret/test-home", isDirectory: true)

  @Test("environment token wins before file and Keychain")
  func environmentWins() throws {
    let credential = try ClaudeUsageClient.resolveCredential(
      environment: [
        "CLAUDE_CODE_OAUTH_TOKEN": "  environment-token  ",
        "ALIGHT_CLAUDE_TOKEN_FILE": "/nonsecret/token"
      ],
      homeDirectory: home,
      readFile: { _ in Issue.record("file should not be read"); return nil },
      readKeychain: { Issue.record("Keychain should not be read"); return "" }
    )

    #expect(credential.accessToken == "environment-token")
    #expect(credential.expiresAt == nil)
  }

  @Test("first non-comment file token wins before Keychain")
  func fileWins() throws {
    let credential = try ClaudeUsageClient.resolveCredential(
      environment: ["ALIGHT_CLAUDE_TOKEN_FILE": "/nonsecret/token"],
      homeDirectory: home,
      readFile: { path in
        #expect(path == "/nonsecret/token")
        return "\n # explanation\n\t\n file-token  \nignored-token\n"
      },
      readKeychain: { Issue.record("Keychain should not be read"); return "" }
    )

    #expect(credential.accessToken == "file-token")
    #expect(credential.expiresAt == nil)
  }

  @Test("default file location is derived from the supplied home")
  func defaultFileLocation() throws {
    let credential = try ClaudeUsageClient.resolveCredential(
      environment: [:],
      homeDirectory: home,
      readFile: { path in
        #expect(path == "/nonsecret/test-home/.alight/claude-token")
        return "default-file-token\n"
      },
      readKeychain: { Issue.record("Keychain should not be read"); return "" }
    )

    #expect(credential.accessToken == "default-file-token")
  }

  @Test("Keychain JSON is the final fallback and preserves expiry")
  func keychainFallback() throws {
    let credential = try ClaudeUsageClient.resolveCredential(
      environment: [:],
      homeDirectory: home,
      readFile: { _ in nil },
      readKeychain: {
        #"{"claudeAiOauth":{"accessToken":" keychain-token ","expiresAt":1800000000000}}"#
      }
    )

    #expect(credential.accessToken == "keychain-token")
    #expect(credential.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
  }

  @Test("malformed Keychain payload fails closed")
  func malformedKeychainFailsClosed() {
    #expect(throws: ClaudeError.self) {
      _ = try ClaudeUsageClient.resolveCredential(
        environment: [:],
        homeDirectory: home,
        readFile: { _ in "# comments only\n \n" },
        readKeychain: { #"{"claudeAiOauth":{}}"# }
      )
    }
  }
}
