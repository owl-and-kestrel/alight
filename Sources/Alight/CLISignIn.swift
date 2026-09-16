import Foundation

/// Launches the appropriate CLI sign-in flow for a provider in Terminal, since
/// the login commands are interactive (browser/OAuth prompts). After signing
/// in, the user can hit Refresh and the hands populate.
enum CLISignIn {
  static func command(for provider: Provider) -> String {
    switch provider {
    case .codex: "codex login"
    case .claude: "claude auth login"
    case .antigravity: "agy"
    }
  }

  static func launch(_ provider: Provider) {
    let script = """
    tell application "Terminal"
      activate
      do script "\(command(for: provider))"
    end tell
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    try? process.run()
  }
}
