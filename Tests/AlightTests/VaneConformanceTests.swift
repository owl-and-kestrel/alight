import Foundation
import Testing
@testable import Alight

@Suite("Vane in JavaScriptCore")
@MainActor
struct VaneConformanceTests {
  /// Mirrors `runVector` in Vane's conformance/fit.test.ts: the vectors'
  /// "Infinity" strings are revived on the way in and restored on the way out,
  /// and refs keep their key order.
  private static let runner = """
    (function (vectorJSON) {
      const vector = JSON.parse(vectorJSON, (_key, item) => (item === "Infinity" ? Infinity : item));
      const vane = AlightCore.vane;
      const tree = vector.input.tree ?? vane.treeFromJson(vector.input.json, vector.input.fromJson ?? {});
      const options = { ...vector.options };
      if (options.store === true) options.store = new vane.MemoryRefStore();
      const result = vane.fitTree(tree, options);
      return JSON.stringify({
        mode: result.metrics.mode, text: result.text, value: result.value,
        omitted: result.omitted, refKeys: Object.keys(result.refs), metrics: result.metrics,
      }, (_key, item) => (item === Infinity ? "Infinity" : item));
    })
    """

  private static func vectorURLs() throws -> [URL] {
    let directory = try #require(Bundle.module.url(forResource: "vane-vectors", withExtension: nil, subdirectory: "Fixtures"))
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  @Test("every Vane conformance vector matches through the bundled core")
  func conformanceVectors() throws {
    let core = try CoreScript.shared.get()
    let run = try #require(try core.evaluate(Self.runner))
    let urls = try Self.vectorURLs()
    #expect(urls.count >= 26)

    for url in urls {
      let vectorJSON = try String(contentsOf: url, encoding: .utf8)
      let vector = try #require(try JSONSerialization.jsonObject(with: Data(vectorJSON.utf8)) as? NSDictionary)
      let expected = try #require(vector["expect"] as? NSDictionary)

      let output = run.call(withArguments: [vectorJSON])
      let outputJSON = try #require(output?.toString(), "\(url.lastPathComponent)")
      let actual = try #require(try JSONSerialization.jsonObject(with: Data(outputJSON.utf8)) as? NSDictionary)
      let name = url.lastPathComponent

      #expect(actual["mode"] as? String == expected["mode"] as? String, "\(name) mode")
      if let text = expected["text"] { #expect(actual["text"] as? NSObject == text as? NSObject, "\(name) text") }
      if let value = expected["value"] { #expect(actual["value"] as? NSObject == value as? NSObject, "\(name) value") }
      #expect(actual["omitted"] as? NSObject == expected["omitted"] as? NSObject, "\(name) omitted")
      #expect(actual["refKeys"] as? NSObject == expected["refs"] as? NSObject, "\(name) refs")
      let metrics = try #require(actual["metrics"] as? NSDictionary)
      for case let (key as String, value) in try #require(expected["metrics"] as? NSDictionary) {
        #expect(metrics[key] as? NSObject == value as? NSObject, "\(name) metrics.\(key)")
      }
    }
  }

  @Test("content refs hash with the host's SHA-256")
  func hostDigest() throws {
    let core = try CoreScript.shared.get()
    let digest = try #require(try core.evaluate("__alightHost.sha256Hex('🦉 Überblick')")?.toString())
    #expect(digest == "a3f2a8cc4815797d4af1a53dba85efba6ddecf14fb4dec3b2a81fccf22108f18")
  }

  @Test("fit ranks by salience and lets the caller's measure cap visible items")
  func fitWithAccept() throws {
    let core = try CoreScript.shared.get()
    let tree = LodNode(id: "root", title: "Usage", children: [
      LodNode(id: "a", title: "Codex weekly", salience: 0.2),
      LodNode(id: "b", title: "Claude 5h", salience: 0.9),
      LodNode(id: "c", title: "Antigravity weekly", salience: 0.5),
      LodNode(id: "d", title: "Claude Fable", salience: 0.1),
    ])

    var calls = 0
    let result = try core.fit(
      tree,
      options: VaneFitOptions(budget: VaneBudget(bytes: 4096), format: .json, order: .rank),
      accept: { value, _ in
        calls += 1
        return (value?.children?.count ?? 0) <= 2
      }
    )

    #expect(calls > 0)
    let visible = try #require(result.value)
    #expect(visible.children?.map(\.id) == ["b", "c"])
    #expect(visible.more?.count == 2)
    #expect(result.metrics.visibleNodes == 3)
  }

  @Test("a JavaScript exception surfaces as a thrown error")
  func exceptionsThrow() throws {
    let core = try CoreScript.shared.get()
    #expect(throws: CoreScript.Failure.self) {
      _ = try core.callString("fitJSON", ["not json", "{}"])
    }
  }
}
