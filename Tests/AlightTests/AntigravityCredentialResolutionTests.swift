import Foundation
import Testing
@testable import Alight

@Suite("Antigravity credential resolution")
struct AntigravityCredentialResolutionTests {
  private let home = URL(fileURLWithPath: "/nonsecret/test-home", isDirectory: true)

  @Test("environment token wins before file and Keychain")
  func environmentWins() async throws {
    let credential = try await AntigravityUsageClient.resolveCredential(
      environment: [
        "ANTIGRAVITY_OAUTH_TOKEN": "  environment-token  ",
        "ALIGHT_ANTIGRAVITY_TOKEN_FILE": "/nonsecret/token"
      ],
      homeDirectory: home,
      readFile: { _ in Issue.record("file should not be read"); return nil },
      readKeychain: { Issue.record("Keychain should not be read"); return "" }
    )

    #expect(credential.accessToken == "environment-token")
    #expect(credential.expiresAt == nil)
  }

  @Test("first non-comment file token wins before CLI files and Keychain")
  func fileWins() async throws {
    let credential = try await AntigravityUsageClient.resolveCredential(
      environment: ["ALIGHT_ANTIGRAVITY_TOKEN_FILE": "/nonsecret/token"],
      homeDirectory: home,
      readFile: { path in
        #expect(path == "/nonsecret/token")
        return "\n # comment line\n\t\n file-token  \nignored-token\n"
      },
      readKeychain: { Issue.record("Keychain should not be read"); return "" }
    )

    #expect(credential.accessToken == "file-token")
    #expect(credential.expiresAt == nil)
  }

  @Test("default file location is derived from the supplied home")
  func defaultFileLocation() async throws {
    let credential = try await AntigravityUsageClient.resolveCredential(
      environment: [:],
      homeDirectory: home,
      readFile: { path in
        if path == "/nonsecret/test-home/.alight/antigravity-token" {
          return "default-file-token\n"
        }
        return nil
      },
      readKeychain: { Issue.record("Keychain should not be read"); return "" }
    )

    #expect(credential.accessToken == "default-file-token")
  }

  @Test("CLI token file is parsed when dedicated token file is absent")
  func cliTokenFileParsed() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let credential = try await AntigravityUsageClient.resolveCredential(
      environment: [:],
      homeDirectory: home,
      readFile: { path in
        if path == "/nonsecret/test-home/.gemini/antigravity-cli/antigravity-oauth-token" {
          return """
          {"token":{"access_token":"cli-token","token_type":"Bearer","refresh_token":"cli-refresh","expiry":"2027-01-15T09:00:00Z"},"auth_method":"consumer"}
          """
        }
        return nil
      },
      readKeychain: { Issue.record("Keychain should not be read"); return "" },
      now: now
    )

    #expect(credential.accessToken == "cli-token")
    #expect(credential.refreshToken == "cli-refresh")
    #expect(credential.expiresAt != nil)
  }

  @Test("Keychain base64 JSON item is decoded and used as fallback")
  func keychainFallback() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let rawJSON = """
    {"token":{"access_token":"keychain-token","token_type":"Bearer","refresh_token":"keychain-refresh","expiry":"2027-01-15T09:00:00Z"},"auth_method":"consumer"}
    """
    let base64 = Data(rawJSON.utf8).base64EncodedString()
    let keychainBlob = "go-keyring-base64:\(base64)"

    let credential = try await AntigravityUsageClient.resolveCredential(
      environment: [:],
      homeDirectory: home,
      readFile: { _ in nil },
      readKeychain: { keychainBlob },
      now: now
    )

    #expect(credential.accessToken == "keychain-token")
    #expect(credential.refreshToken == "keychain-refresh")
  }

  @Test("expired token triggers refresh handler")
  func expiredTokenRefreshed() async throws {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let rawJSON = """
    {"token":{"access_token":"expired-token","token_type":"Bearer","refresh_token":"valid-refresh","expiry":"2027-01-15T09:00:00Z"},"auth_method":"consumer"}
    """
    let base64 = Data(rawJSON.utf8).base64EncodedString()
    let keychainBlob = "go-keyring-base64:\(base64)"

    let credential = try await AntigravityUsageClient.resolveCredential(
      environment: [:],
      homeDirectory: home,
      readFile: { _ in nil },
      readKeychain: { keychainBlob },
      now: now,
      refreshTokenHandler: { refreshToken in
        #expect(refreshToken == "valid-refresh")
        return AntigravityCredential(accessToken: "fresh-access-token", expiresAt: now.addingTimeInterval(3600), refreshToken: refreshToken)
      }
    )

    #expect(credential.accessToken == "fresh-access-token")
    #expect(credential.refreshToken == "valid-refresh")
  }

  @Test("malformed Keychain payload fails closed")
  func malformedKeychainFailsClosed() async {
    await #expect(throws: AntigravityError.self) {
      _ = try await AntigravityUsageClient.resolveCredential(
        environment: [:],
        homeDirectory: home,
        readFile: { _ in "# comments only\n \n" },
        readKeychain: { "go-keyring-base64:not-valid-base64!" }
      )
    }
  }
}
