import Foundation
import Testing
@testable import Alight

@Suite("Antigravity credential resolution")
struct AntigravityCredentialResolutionTests {
  private let home = URL(fileURLWithPath: "/nonsecret/test-home", isDirectory: true)

  @Test("environment token wins before file and Keychain")
  func environmentWins() throws {
    let credential = try AntigravityUsageClient.resolveCredential(
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
  func fileWins() throws {
    let credential = try AntigravityUsageClient.resolveCredential(
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
  func defaultFileLocation() throws {
    let credential = try AntigravityUsageClient.resolveCredential(
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
  func cliTokenFileParsed() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let credential = try AntigravityUsageClient.resolveCredential(
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
    #expect(credential.expiresAt != nil)
  }

  @Test("Keychain base64 JSON item is decoded and used as fallback")
  func keychainFallback() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let rawJSON = """
    {"token":{"access_token":"keychain-token","token_type":"Bearer","refresh_token":"keychain-refresh","expiry":"2027-01-15T09:00:00Z"},"auth_method":"consumer"}
    """
    let base64 = Data(rawJSON.utf8).base64EncodedString()
    let keychainBlob = "go-keyring-base64:\(base64)"

    let credential = try AntigravityUsageClient.resolveCredential(
      environment: [:],
      homeDirectory: home,
      readFile: { _ in nil },
      readKeychain: { keychainBlob },
      now: now
    )

    #expect(credential.accessToken == "keychain-token")
  }

  private func keychainBlob(expiry: String) -> String {
    let rawJSON = """
    {"token":{"access_token":"\(expiry)-token","token_type":"Bearer","refresh_token":"unused-refresh","expiry":"\(expiry)"},"auth_method":"consumer"}
    """
    return "go-keyring-base64:\(Data(rawJSON.utf8).base64EncodedString())"
  }

  private let expiredCLIFile = """
    {"token":{"access_token":"expired-file-token","refresh_token":"unused-refresh","expiry":"2027-01-15T09:00:00Z"}}
    """
  private let cliFilePath = "/nonsecret/test-home/.gemini/antigravity-cli/antigravity-oauth-token"
  /// After every fixture expiry above.
  private let afterExpiry = Date(timeIntervalSince1970: 1_900_000_000)

  @Test("expired Keychain token is reported as expired, never refreshed")
  func expiredKeychainTokenIsExpired() {
    let blob = keychainBlob(expiry: "2027-01-15T09:00:00Z")
    do {
      _ = try AntigravityUsageClient.resolveCredential(
        environment: [:], homeDirectory: home, readFile: { _ in nil },
        readKeychain: { blob }, now: afterExpiry
      )
      Issue.record("expected tokenExpired")
    } catch AntigravityError.tokenExpired {
    } catch {
      Issue.record("expected tokenExpired, got \(error)")
    }
  }

  @Test("expired CLI file with no Keychain item is expired, not 'not signed in'")
  func expiredFileWithoutKeychainIsExpired() {
    let path = cliFilePath
    let contents = expiredCLIFile
    do {
      _ = try AntigravityUsageClient.resolveCredential(
        environment: [:],
        homeDirectory: home,
        readFile: { $0 == path ? contents : nil },
        readKeychain: { throw AntigravityError.notSignedIn },
        now: afterExpiry
      )
      Issue.record("expected tokenExpired")
    } catch AntigravityError.tokenExpired {
    } catch {
      Issue.record("expected tokenExpired, got \(error)")
    }
  }

  @Test("expired CLI file with an unusable Keychain payload is expired")
  func expiredFileWithMalformedKeychainIsExpired() {
    let path = cliFilePath
    let contents = expiredCLIFile
    do {
      _ = try AntigravityUsageClient.resolveCredential(
        environment: [:],
        homeDirectory: home,
        readFile: { $0 == path ? contents : nil },
        readKeychain: { "go-keyring-base64:not-valid-base64!" },
        now: afterExpiry
      )
      Issue.record("expected tokenExpired")
    } catch AntigravityError.tokenExpired {
    } catch {
      Issue.record("expected tokenExpired, got \(error)")
    }
  }

  @Test("no credential anywhere stays 'not signed in'")
  func missingCredentialIsNotSignedIn() {
    do {
      _ = try AntigravityUsageClient.resolveCredential(
        environment: [:],
        homeDirectory: home,
        readFile: { _ in nil },
        readKeychain: { throw AntigravityError.notSignedIn },
        now: afterExpiry
      )
      Issue.record("expected notSignedIn")
    } catch AntigravityError.notSignedIn {
    } catch {
      Issue.record("expected notSignedIn, got \(error)")
    }
  }

  @Test("a current Keychain token is used when the CLI file has expired")
  func currentKeychainBeatsExpiredFile() throws {
    let path = cliFilePath
    let contents = expiredCLIFile
    let blob = keychainBlob(expiry: "2099-01-01T00:00:00Z")
    let credential = try AntigravityUsageClient.resolveCredential(
      environment: [:],
      homeDirectory: home,
      readFile: { $0 == path ? contents : nil },
      readKeychain: { blob },
      now: afterExpiry
    )
    #expect(credential.accessToken == "2099-01-01T00:00:00Z-token")
  }

  @Test("refresh tokens are never read from credential files")
  func refreshTokenIsIgnored() throws {
    let credential = try #require(
      AntigravityUsageClient.parseTokenJSON(
        #"{"access_token":"a-token","refresh_token":"must-be-ignored","expiry_date":4102444800000}"#
      )
    )
    #expect(credential.accessToken == "a-token")
    #expect(credential.expiresAt != nil)
    #expect(Mirror(reflecting: credential).children.map(\.label) == ["accessToken", "expiresAt"])
  }

  @Test("expired and rejected sessions tell the user to run agy and ask for sign-in")
  func expiredSessionMessaging() {
    let expired = AntigravityUsageClient.describe(AntigravityError.tokenExpired)
    #expect(expired == "session expired — run `agy` to refresh")
    #expect(
      AntigravityUsageClient.describe(AntigravityError.fetchFailed(401, retryAfter: nil)) == expired
    )
    #expect(CLISignIn.command(for: .antigravity) == "agy")
    let failure = ProviderResult.failure(.antigravity, source: "error", error: expired, needsAuth: true)
    #expect(!failure.ok)
    #expect(failure.windows.isEmpty)
    #expect(failure.needsAuth)
  }

  @Test("malformed Keychain payload fails closed")
  func malformedKeychainFailsClosed() {
    #expect(throws: AntigravityError.self) {
      _ = try AntigravityUsageClient.resolveCredential(
        environment: [:],
        homeDirectory: home,
        readFile: { _ in "# comments only\n \n" },
        readKeychain: { "go-keyring-base64:not-valid-base64!" }
      )
    }
  }
}
