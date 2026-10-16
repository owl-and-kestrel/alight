import CryptoKit
import Foundation
import JavaScriptCore

/// Runs Alight's bundled upstream JavaScript (`alight-core.js`: Vane's tree
/// fitter) in JavaScriptCore. The logic is maintained upstream and bundled by
/// `scripts/build-core.mjs`; this type only loads the bundle and supplies the
/// host functions its Node shims call. One context, used from the main actor.
@MainActor
final class CoreScript {
  enum Failure: Error, CustomStringConvertible {
    case bundleMissing
    case exception(String)
    case unexpectedResult(String)

    var description: String {
      switch self {
      case .bundleMissing: "alight-core.js is missing from the app bundle"
      case .exception(let message): "alight-core: \(message)"
      case .unexpectedResult(let detail): "alight-core returned \(detail)"
      }
    }
  }

  /// The app's shared instance; a broken bundle is reported, not fatal.
  static let shared: Result<CoreScript, Error> = Result { try CoreScript(source: bundledSource()) }

  private let context: JSContext
  private let core: JSValue

  init(source: String) throws {
    guard let context = JSContext() else { throw Failure.exception("no JavaScriptCore context") }
    self.context = context

    // The bundle's node:crypto shim calls this for Vane's content refs.
    let sha256Hex: @convention(block) (String) -> String = { text in
      SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    let host = JSValue(newObjectIn: context)
    host?.setObject(sha256Hex, forKeyedSubscript: "sha256Hex" as NSString)
    context.setObject(host, forKeyedSubscript: "__alightHost" as NSString)

    context.evaluateScript(source)
    try Self.takeException(from: context)
    guard let core = context.objectForKeyedSubscript("AlightCore"), core.isObject else {
      throw Failure.unexpectedResult("no AlightCore global")
    }
    self.core = core
  }

  static func bundledSource() throws -> String {
    // The app carries the bundle in Contents/Resources; `swift run` and tests
    // find SwiftPM's resource bundle instead.
    guard
      let url = Bundle.main.url(forResource: "alight-core", withExtension: "js")
        ?? Bundle.module.url(forResource: "alight-core", withExtension: "js")
    else { throw Failure.bundleMissing }
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// Calls the exported `AlightCore.<function>` and returns its string result.
  func callString(_ function: String, _ arguments: [Any]) throws -> String {
    let result = core.objectForKeyedSubscript(function).call(withArguments: arguments)
    try Self.takeException(from: context)
    guard let result, result.isString, let string = result.toString() else {
      throw Failure.unexpectedResult("a non-string from \(function)")
    }
    return string
  }

  /// Evaluates `script` in the core's context (tests drive upstream exports
  /// directly through this).
  func evaluate(_ script: String) throws -> JSValue? {
    let result = context.evaluateScript(script)
    try Self.takeException(from: context)
    return result
  }

  /// Wraps a Swift block as a JavaScript function value in this context.
  func function(_ block: Any) -> JSValue {
    JSValue(object: block, in: context)
  }

  private static func takeException(from context: JSContext) throws {
    guard let exception = context.exception else { return }
    context.exception = nil
    let message = exception.toString() ?? "unknown exception"
    let stack = exception.objectForKeyedSubscript("stack")?.toString() ?? ""
    throw Failure.exception(stack.isEmpty || stack == "undefined" ? message : "\(message)\n\(stack)")
  }
}
