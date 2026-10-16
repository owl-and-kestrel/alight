import Foundation
import JavaScriptCore

/// Swift mirrors of the parts of Vane's contract (`@owl-kestrel/vane`, SPEC
/// §8) that Alight uses. Ranking, level-of-detail and budget search all stay
/// in Vane; `CoreScript.fit` only moves JSON across.
struct LodNode: Codable, Equatable, Sendable {
  var id: String?
  var kind: String?
  var title: String
  var summary: String?
  var detail: String?
  /// 0 (highest) through 9.
  var priority: Int?
  var weight: Double?
  /// 0...1.
  var salience: Double?
  var status: String?
  var severity: String?
  /// 0, 1 or 2 makes a field-like child; nil is a ranked collection item.
  var tier: Int?
  var pinned: Bool?
  var ref: String?
  var children: [LodNode]?

  init(
    id: String? = nil, kind: String? = nil, title: String, summary: String? = nil,
    detail: String? = nil, priority: Int? = nil, weight: Double? = nil, salience: Double? = nil,
    status: String? = nil, severity: String? = nil, tier: Int? = nil, pinned: Bool? = nil,
    ref: String? = nil, children: [LodNode]? = nil
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.summary = summary
    self.detail = detail
    self.priority = priority
    self.weight = weight
    self.salience = salience
    self.status = status
    self.severity = severity
    self.tier = tier
    self.pinned = pinned
    self.ref = ref
    self.children = children
  }
}

struct VaneBudget: Codable, Equatable, Sendable {
  var bytes: Int?
  var chars: Int?
  var tokens: Int?
}

struct VaneFitOptions: Encodable, Sendable {
  enum Format: String, Encodable, Sendable { case text, json }
  enum Order: String, Encodable, Sendable { case source, rank }

  var budget: VaneBudget?
  var format: Format?
  var order: Order?
  /// Node ids or refs pinned (with their ancestors) regardless of rank.
  var focus: [String]?
}

/// Vane's node-shaped JSON output: the visible part of a fitted LodNode tree.
struct VaneVisibleNode: Decodable, Equatable, Sendable {
  struct More: Decodable, Equatable, Sendable {
    var count: Int
    var by: [String: Int]?
    var ref: String?
  }

  var id: String?
  var title: String
  var summary: String?
  var detail: String?
  var children: [VaneVisibleNode]?
  var more: More?
}

struct VaneFitResult: Decodable, Sendable {
  struct Omission: Decodable, Equatable, Sendable {
    var path: [Int]
    var title: String
    var count: Int
    var hiddenNodes: Int
    var hiddenIndexes: [Int]
    var by: [String: Int]
    var ref: String?
  }

  struct Metrics: Decodable, Equatable, Sendable {
    var mode: String
    var totalNodes: Int
    var visibleNodes: Int
    var coverage: Double
  }

  var text: String
  /// Present for `format: .json`.
  var value: VaneVisibleNode?
  var omitted: [Omission]
  var metrics: Metrics
}

extension CoreScript {
  /// Fits `tree` with Vane. `accept`, the caller's own measure, sees each
  /// candidate's visible tree (JSON format) and text and is ANDed with the
  /// budget, so a renderer can impose a limit Vane cannot measure.
  func fit(
    _ tree: LodNode,
    options: VaneFitOptions,
    accept: ((VaneVisibleNode?, String) -> Bool)? = nil
  ) throws -> VaneFitResult {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let treeJSON = String(decoding: try encoder.encode(tree), as: UTF8.self)
    let optionsJSON = String(decoding: try encoder.encode(options), as: UTF8.self)

    var arguments: [Any] = [treeJSON, optionsJSON]
    if let accept {
      let decoder = JSONDecoder()
      let block: @convention(block) (String, String) -> Bool = { valueJSON, text in
        let value = try? decoder.decode(VaneVisibleNode?.self, from: Data(valueJSON.utf8))
        // JavaScriptCore calls back synchronously on the calling (main) thread.
        return MainActor.assumeIsolated { accept(value ?? nil, text) }
      }
      arguments.append(function(block))
    }

    let resultJSON = try callString("fitJSON", arguments)
    return try JSONDecoder().decode(VaneFitResult.self, from: Data(resultJSON.utf8))
  }
}
