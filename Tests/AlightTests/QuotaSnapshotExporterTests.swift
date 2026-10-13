import Foundation
import Testing
@testable import Alight

@Suite("Quota snapshot exporter")
struct QuotaSnapshotExporterTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)
  private static let producer = QuotaSnapshot.Producer(
    app: QuotaSnapshot.producerApp, version: "1.3.3", build: "42", sourceCommit: String(repeating: "ab", count: 20))
  private static let endpointRef = String(repeating: "e", count: 64)

  // The v1 key sets, copied from Fieldbook `src/quota/alight-snapshot.mjs`.
  private static let snapshotKeys: Set = ["schema", "producer", "installId", "sequence", "writtenAt", "providers"]
  private static let producerKeys: Set = ["app", "version", "build", "sourceCommit"]
  private static let providerKeys: Set = [
    "provider", "status", "attemptedAt", "capturedAt", "readingSource", "cacheAgeSeconds",
    "accountRef", "endpointRef", "failure", "groups",
  ]
  private static let failureKeys: Set = ["code", "needsAuth"]
  private static let groupKeys: Set = ["providerGroup", "windows"]
  private static let providerGroupKeys: Set = ["displayName", "bucketIds"]
  private static let windowKeys: Set = [
    "windowId", "cadence", "usedPercentRaw", "usedPercentPrecision", "resetAt", "resetSource",
    "windowSeconds", "windowSecondsSource", "providerBucketId", "scope",
  ]
  private static let scopeKeys: Set = ["kind", "key", "displayName"]

  // MARK: Fixtures

  /// Two Antigravity groups (Gemini and the 3P models), as the endpoint reports them.
  private static var antigravityPayload: [String: Any] { [
    "groups": [
      [
        "displayName": "Gemini Models",
        "buckets": [
          ["bucketId": "gemini-5h", "window": "5h", "resetTime": "2027-01-15T09:00:00Z", "remainingFraction": 0.75],
          ["bucketId": "gemini-weekly", "window": "weekly", "resetTime": "2027-01-20T09:00:00Z", "remainingFraction": 0.5],
        ],
      ],
      [
        "displayName": "Claude and GPT models",
        "buckets": [
          ["bucketId": "3p-5h", "window": "5h", "resetTime": "2027-01-15T10:00:00Z", "remainingFraction": 0.7],
          // Over the limit: a negative remaining fraction is real data.
          ["bucketId": "3p-weekly", "window": "weekly", "resetTime": "2027-01-20T10:00:00Z", "remainingFraction": -0.25],
        ],
      ],
    ],
  ] }

  private static func claudeText(_ lines: [String]) -> String { lines.joined(separator: "\n") }

  private static func antigravityResult() throws -> ProviderResult {
    var result = ProviderResult(
      provider: .antigravity, ok: true, source: "live", error: nil,
      windows: AntigravityUsageParser.windows(from: antigravityPayload, now: now))
    let report = try #require(AntigravityUsageParser.quotaReport(from: antigravityPayload))
    result.quotaReport = report
    return result
  }

  private static func claudeResult(_ text: String) throws -> ProviderResult {
    let reading = try ClaudeUsageParser.reading(fromText: text, now: now)
    var result = ProviderResult(provider: .claude, ok: true, source: "live", error: nil, windows: reading.windows)
    result.quotaReport = reading.report
    result.accountRef = UsageAccountRef.digest(
      provider: .claude, organization: "org-1", identifier: " Person@Example.com ", kind: .email)
    return result
  }

  private static func codexResult(usedPercent: Double = 3) throws -> ProviderResult {
    let json = """
      {"rate_limit":{"primary_window":{"used_percent":\(usedPercent),"reset_at":1800300000,"limit_window_seconds":604800}}}
      """
    let payload = try JSONDecoder().decode(UsagePayload.self, from: Data(json.utf8))
    var result = ProviderResult(
      provider: .codex, ok: true, source: "live", error: nil, windows: CodexUsageParser.windows(from: payload, now: now))
    result.quotaReport = CodexUsageParser.quotaReport(from: payload)
    result.accountRef = UsageAccountRef.digest(provider: .codex, organization: nil, identifier: "acct-123", kind: .opaque)
    return result
  }

  private static let claudeLines = claudeText([
    "Current session: 16% used · resets Jan 15, 2027 at 2pm (UTC)",
    "Current week (all models): 40% used · resets Jan 18, 2027 at 9am (UTC)",
    "Current week (Fable): 0% used",
  ])

  private static func observedInputs() throws -> [QuotaSnapshotExporter.Input] {
    let live = now.addingTimeInterval(2)
    return [
      .init(result: try codexResult(), attemptedAt: now, liveCapturedAt: live),
      .init(result: try claudeResult(claudeLines), attemptedAt: now, liveCapturedAt: live),
      .init(result: try antigravityResult(), attemptedAt: now, liveCapturedAt: live),
    ]
  }

  private static func snapshot(_ inputs: [QuotaSnapshotExporter.Input], sequence: Int = 7) -> QuotaSnapshot {
    QuotaSnapshotExporter.snapshot(
      inputs, producer: producer, installId: "install-1", sequence: sequence,
      writtenAt: now.addingTimeInterval(3), antigravityEndpointRef: endpointRef)
  }

  private static func json(_ snapshot: QuotaSnapshot) throws -> [String: Any] {
    let data = try QuotaSnapshotExporter.encode(snapshot)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private static func entry(_ snapshot: QuotaSnapshot, _ provider: Provider) throws -> QuotaSnapshot.ProviderEntry {
    try #require(snapshot.providers.first { $0.provider == provider })
  }

  private static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "alight-quota-snapshot-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Writes a sample for the Fieldbook cross-check when
  /// `ALIGHT_QUOTA_SNAPSHOT_FIXTURE_DIR` names a directory.
  private static func emitFixture(_ name: String, _ snapshot: QuotaSnapshot) throws {
    guard let directory = ProcessInfo.processInfo.environment["ALIGHT_QUOTA_SNAPSHOT_FIXTURE_DIR"], !directory.isEmpty else {
      return
    }
    try QuotaSnapshotExporter.encode(snapshot).write(to: URL(fileURLWithPath: directory).appending(path: "\(name).json"))
  }

  // MARK: Shape

  @Test("the document has exactly the v1 keys at every level, with explicit nulls")
  func closedShape() throws {
    let snapshot = Self.snapshot(try Self.observedInputs())
    try Self.emitFixture("observed", snapshot)
    let root = try Self.json(snapshot)

    #expect(Set(root.keys) == Self.snapshotKeys)
    #expect(root["schema"] as? String == "ok.alight.quota-snapshot.v1")
    #expect(root["installId"] as? String == "install-1")
    #expect(root["sequence"] as? Int == 7)
    #expect(root["writtenAt"] as? String == "2027-01-15T08:00:03.000Z")
    let producer = try #require(root["producer"] as? [String: Any])
    #expect(Set(producer.keys) == Self.producerKeys)
    #expect(producer["app"] as? String == "com.owlandkestrel.alight")

    let providers = try #require(root["providers"] as? [[String: Any]])
    #expect(providers.map { $0["provider"] as? String } == ["antigravity", "claude", "codex"])
    for provider in providers {
      #expect(Set(provider.keys) == Self.providerKeys)
      #expect(provider["status"] as? String == "observed")
      #expect(provider["failure"] is NSNull)
      #expect(provider["cacheAgeSeconds"] is NSNull)
      #expect(provider["readingSource"] as? String == "live")
      #expect(provider["attemptedAt"] as? String == "2027-01-15T08:00:00.000Z")
      #expect(provider["capturedAt"] as? String == "2027-01-15T08:00:02.000Z")
      for group in try #require(provider["groups"] as? [[String: Any]]) {
        #expect(Set(group.keys) == Self.groupKeys)
        if let named = group["providerGroup"] as? [String: Any] {
          #expect(Set(named.keys) == Self.providerGroupKeys)
        } else {
          #expect(group["providerGroup"] is NSNull)
        }
        for window in try #require(group["windows"] as? [[String: Any]]) {
          #expect(Set(window.keys) == Self.windowKeys)
          if let scope = window["scope"] as? [String: Any] {
            #expect(Set(scope.keys) == Self.scopeKeys)
          } else {
            #expect(window["scope"] is NSNull)
          }
        }
      }
    }
    #expect(providers[0]["endpointRef"] as? String == Self.endpointRef)
    #expect(providers[1]["endpointRef"] is NSNull)
  }

  @Test("Claude windows map to session, week, and a model-scoped Fable week with an unreported reset")
  func claudeWindows() throws {
    let claude = try Self.entry(Self.snapshot(try Self.observedInputs()), .claude)
    let group = try #require(claude.groups.first)
    #expect(claude.groups.count == 1)
    #expect(group.providerGroup == nil)
    #expect(group.windows.map(\.windowId) == ["session", "week", "week"])
    #expect(group.windows.map(\.cadence) == ["5h", "weekly", "weekly"])
    #expect(group.windows.map(\.windowSeconds) == [18_000, 604_800, 604_800])
    #expect(group.windows.map(\.windowSecondsSource) == ["label", "label", "label"])
    #expect(group.windows.map(\.usedPercentPrecision) == ["floor_integer", "floor_integer", "floor_integer"])
    #expect(group.windows[0].resetAt == "2027-01-15T14:00:00.000Z")
    #expect(group.windows[0].resetSource == "provider")
    // Claude Code prints no reset for an unused window. The display invents
    // "now + 7 days"; the export says unknown.
    #expect(group.windows[2].resetAt == nil)
    #expect(group.windows[2].resetSource == "unknown")
    #expect(group.windows[2].scope == .init(kind: "model", key: "fable", displayName: "Fable"))
  }

  @Test("every Antigravity group is exported verbatim, including the third-party group (A-1)")
  func antigravityGroups() throws {
    let antigravity = try Self.entry(Self.snapshot(try Self.observedInputs()), .antigravity)
    #expect(antigravity.groups.map(\.providerGroup) == [
      QuotaProviderGroup(displayName: "Gemini Models", bucketIds: ["gemini-5h", "gemini-weekly"]),
      QuotaProviderGroup(displayName: "Claude and GPT models", bucketIds: ["3p-5h", "3p-weekly"]),
    ])
    let thirdParty = antigravity.groups[1].windows
    #expect(thirdParty.map(\.windowId) == ["session", "week"])
    #expect(thirdParty.map(\.providerBucketId) == ["3p-5h", "3p-weekly"])
    #expect(thirdParty.allSatisfy { $0.scope == nil && $0.windowSecondsSource == "label" })
    #expect(thirdParty[0].usedPercentRaw == 30)
  }

  @Test("Antigravity facts are refused, not defaulted, when the endpoint omits them")
  func antigravityRefusesMissingFacts() {
    func report(_ bucket: [String: Any]) -> QuotaReport? {
      AntigravityUsageParser.quotaReport(from: ["groups": [["displayName": "Gemini Models", "buckets": [bucket]]]])
    }
    #expect(report(["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.5]) != nil)
    #expect(report(["bucketId": "gemini-5h", "window": "5h"]) == nil)
    #expect(report(["bucketId": "gemini-x", "remainingFraction": 0.5]) == nil)
    #expect(report(["bucketId": "gemini-5h", "window": "weekly", "remainingFraction": 0.5]) == nil)
    #expect(report(["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.5, "resetTime": "soon"]) == nil)
    let noReset = report(["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.5])
    #expect(noReset?.groups.first?.windows.first?.resetAt == nil)
  }

  // MARK: Raw values

  @Test("values above 100 are exported raw while the display clamps")
  func overLimitKeptRaw() throws {
    let codex = try Self.codexResult(usedPercent: 137.5)
    #expect(codex.windows.first?.usedPercent == 100)
    let claude = try Self.claudeResult(Self.claudeText([
      "Current session: 105% used · resets Jan 15, 2027 at 2pm (UTC)",
    ]))
    #expect(claude.windows.first?.usedPercent == 100)
    let antigravity = try Self.antigravityResult()
    #expect(antigravity.windows.allSatisfy { $0.usedPercent <= 100 })

    let snapshot = Self.snapshot([
      .init(result: codex, attemptedAt: Self.now, liveCapturedAt: Self.now),
      .init(result: claude, attemptedAt: Self.now, liveCapturedAt: Self.now),
      .init(result: antigravity, attemptedAt: Self.now, liveCapturedAt: Self.now),
    ])
    try Self.emitFixture("over-limit", snapshot)
    #expect(try Self.entry(snapshot, .codex).groups[0].windows[0].usedPercentRaw == 137.5)
    let claudeWindow = try Self.entry(snapshot, .claude).groups[0].windows[0]
    #expect(claudeWindow.usedPercentRaw == 105)
    #expect(claudeWindow.usedPercentPrecision == "floor_integer")
    #expect(try Self.entry(snapshot, .antigravity).groups[1].windows[1].usedPercentRaw == 125)
  }

  @Test("a negative or non-finite value is refused: the provider fails, never clamps")
  func negativeRefused() throws {
    // "120% left" would be -20% used. The display shows 0; the export refuses.
    let claude = try Self.claudeResult(Self.claudeText([
      "Current session: 120% left · resets Jan 15, 2027 at 2pm (UTC)",
    ]))
    #expect(claude.ok)
    #expect(claude.quotaReport == nil)
    let entry = QuotaSnapshotExporter.providerEntry(
      .init(result: claude, attemptedAt: Self.now, liveCapturedAt: Self.now), antigravityEndpointRef: nil)
    #expect(entry.status == .failed)
    #expect(entry.failure == .init(code: .parseFailed, needsAuth: false))
    #expect(entry.groups.isEmpty)
    #expect(entry.capturedAt == nil)

    let window = QuotaReportWindow(
      windowSeconds: 18_000, windowSecondsSource: .provider, usedPercentRaw: .infinity,
      usedPercentPrecision: .unverified, resetAt: nil, providerBucketId: nil, scope: nil)
    #expect(QuotaSnapshotExporter.exportWindow(window, grouped: false) == nil)
    let fractionalFloor = QuotaReportWindow(
      windowSeconds: 18_000, windowSecondsSource: .label, usedPercentRaw: 40.5,
      usedPercentPrecision: .floorInteger, resetAt: nil, providerBucketId: nil, scope: nil)
    #expect(QuotaSnapshotExporter.exportWindow(fractionalFloor, grouped: false) == nil)
  }

  @Test("a 'left' or decimal Claude figure is unverified precision")
  func claudePrecision() throws {
    let claude = try Self.claudeResult(Self.claudeText([
      "Current session: 84% left · resets Jan 15, 2027 at 2pm (UTC)",
      "Current week (all models): 40.5% used · resets Jan 18, 2027 at 9am (UTC)",
    ]))
    let windows = try #require(claude.quotaReport?.groups.first?.windows)
    #expect(windows.map(\.usedPercentRaw) == [16, 40.5])
    #expect(windows.map(\.usedPercentPrecision) == [.unverified, .unverified])
  }

  @Test("duplicate reader window keys fail only that provider")
  func duplicateWindowKeys() {
    let window = QuotaReportWindow(
      windowSeconds: 18_000, windowSecondsSource: .label, usedPercentRaw: 1,
      usedPercentPrecision: .unverified, resetAt: nil, providerBucketId: "a-5h", scope: nil)
    // Two non-Gemini groups whose names give the same Fieldbook slug.
    let report = QuotaReport(groups: [
      QuotaReportGroup(providerGroup: .init(displayName: "3P models", bucketIds: ["a-5h"]), windows: [window]),
      QuotaReportGroup(providerGroup: .init(displayName: "3p  Models", bucketIds: ["a-5h"]), windows: [window]),
    ])
    #expect(QuotaSnapshotExporter.fieldbookGroupSlug("3p  Models!") == "3p_models_")
    #expect(QuotaSnapshotExporter.exportGroups(report, provider: .antigravity) == nil)
    #expect(QuotaSnapshotExporter.exportGroups(QuotaReport(groups: [report.groups[0]]), provider: .antigravity) != nil)
    // A grouped report is refused for Claude and Codex, and an ungrouped one for Antigravity.
    #expect(QuotaSnapshotExporter.exportGroups(QuotaReport(groups: [report.groups[0]]), provider: .codex) == nil)
    let ungrouped = QuotaReport(groups: [QuotaReportGroup(providerGroup: nil, windows: [window])])
    #expect(QuotaSnapshotExporter.exportGroups(ungrouped, provider: .antigravity) == nil)
  }

  // MARK: Statuses

  @Test("failed, signed-out, refused, and deferred providers are explicit statuses, never available")
  func failureStatuses() throws {
    let cases: [(ProviderResult, QuotaSnapshot.Status, QuotaSnapshot.Failure?)] = [
      (.failure(.codex, source: "error", error: "usage fetch failed", failureCode: .network),
       .failed, .init(code: .network, needsAuth: false)),
      (.failure(.codex, source: "error", error: "no Codex auth", needsAuth: true, failureCode: .authRequired),
       .signedOut, .init(code: .authRequired, needsAuth: true)),
      (.failure(.claude, source: ClaudeUsageClient.signedOutSource, error: "not signed in", needsAuth: true),
       .signedOut, .init(code: .authRequired, needsAuth: true)),
      (.failure(.claude, source: ClaudeUsageClient.refusedSource, error: "Stopped"),
       .refused, .init(code: .refused, needsAuth: false)),
      (.failure(.claude, source: "deferred", error: "next live poll in 2m"), .deferred, nil),
      (.failure(.antigravity, source: "error", error: "rate-limited", failureCode: .rateLimited),
       .failed, .init(code: .rateLimited, needsAuth: false)),
      (.failure(.antigravity, source: "error", error: "something"), .failed, .init(code: .unknown, needsAuth: false)),
      // ok with no windows is not availability either.
      (ProviderResult(provider: .codex, ok: true, source: "live", error: nil, windows: []),
       .failed, .init(code: .unknown, needsAuth: false)),
    ]
    for (result, status, failure) in cases {
      let entry = QuotaSnapshotExporter.providerEntry(
        .init(result: result, attemptedAt: Self.now, liveCapturedAt: Self.now), antigravityEndpointRef: Self.endpointRef)
      #expect(entry.status == status, "\(result.source) \(result.error ?? "")")
      #expect(entry.failure == failure)
      #expect(entry.capturedAt == nil)
      #expect(entry.groups.isEmpty)
      #expect(entry.readingSource == "live")
    }

    let failed = Self.snapshot([
      .init(result: .failure(.codex, source: "error", error: "x", failureCode: .network), attemptedAt: Self.now, liveCapturedAt: Self.now),
      .init(result: .failure(.claude, source: ClaudeUsageClient.signedOutSource, error: "x", needsAuth: true),
            attemptedAt: Self.now, liveCapturedAt: nil),
      .init(result: .failure(.antigravity, source: "error", error: "x", failureCode: .rateLimited),
            attemptedAt: Self.now, liveCapturedAt: Self.now),
    ])
    try Self.emitFixture("failures", failed)
    let root = try Self.json(failed)
    for provider in try #require(root["providers"] as? [[String: Any]]) {
      #expect(Set(provider.keys) == Self.providerKeys)
      #expect(provider["capturedAt"] is NSNull)
      #expect(provider["status"] as? String != "observed")
    }
  }

  @Test("an observed reading without exportable facts is a parse failure")
  func observedWithoutReport() {
    let window = PressureMath.window(
      provider: .codex, speed: .slow, usedPercent: 3, resetAt: Self.now.addingTimeInterval(3600),
      limitWindowSeconds: 604_800, now: Self.now)
    let legacy = ProviderResult(provider: .codex, ok: true, source: "live", error: nil, windows: [window])
    let entry = QuotaSnapshotExporter.providerEntry(
      .init(result: legacy, attemptedAt: Self.now, liveCapturedAt: Self.now), antigravityEndpointRef: nil)
    #expect(entry.status == .failed)
    #expect(entry.failure?.code == .parseFailed)
  }

  // MARK: Cache

  @Test("a cached reading keeps its own capture time and facts, with no rebasing")
  func cachedReading() throws {
    var cache = UsageResultCache(persistenceURL: nil)
    let live = try Self.codexResult(usedPercent: 137.5)
    _ = cache.reconcile(live, now: Self.now)
    let later = Self.now.addingTimeInterval(600)
    let cached = cache.reconcile(.failure(.codex, source: "error", error: "x", failureCode: .network), now: later)
    #expect(cached.source == "cached")
    #expect(cached.capturedAt == Self.now)
    #expect(cached.quotaReport == live.quotaReport)

    let snapshot = Self.snapshot([.init(result: cached, attemptedAt: later, liveCapturedAt: later)])
    try Self.emitFixture("cached", snapshot)
    let entry = try Self.entry(snapshot, .codex)
    #expect(entry.status == .observed)
    #expect(entry.readingSource == "cached")
    #expect(entry.capturedAt == "2027-01-15T08:00:00.000Z")
    #expect(entry.attemptedAt == "2027-01-15T08:10:00.000Z")
    #expect(entry.cacheAgeSeconds == 600)
    // The cache cannot tell which Codex account a cached reading belongs to.
    #expect(entry.accountRef == nil)
    #expect(entry.groups[0].windows[0].usedPercentRaw == 137.5)
  }

  @Test("the persisted cache keeps report facts across a relaunch and still loads older documents")
  func cachePersistsReport() throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "usage-cache.json")
    var first = UsageResultCache(persistenceURL: url)
    let live = try Self.codexResult()
    _ = first.reconcile(live, now: Self.now)
    var relaunched = UsageResultCache(persistenceURL: url)
    let cached = relaunched.reconcile(.failure(.codex, source: "error", error: "x"), now: Self.now.addingTimeInterval(60))
    #expect(cached.quotaReport == live.quotaReport)
    #expect(UsageResultCache.isValidPersistedCache(at: url))
  }

  // MARK: Sequence and file

  @Test("sequence increases by one per write and resumes from the previous file")
  func sequenceMonotonic() throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var ids = ["install-a", "install-b"]
    let makeId = { ids.removeFirst() }
    var exporter = QuotaSnapshotExporter(
      directory: directory, producer: Self.producer, antigravityEndpointRef: Self.endpointRef, makeInstallId: makeId)
    let inputs = try Self.observedInputs()
    #expect(exporter.export(inputs, writtenAt: Self.now) == .written(sequence: 0))
    #expect(exporter.export(inputs, writtenAt: Self.now) == .written(sequence: 1))
    #expect(exporter.export(inputs, writtenAt: Self.now) == .written(sequence: 2))

    var relaunched = QuotaSnapshotExporter(
      directory: directory, producer: Self.producer, antigravityEndpointRef: Self.endpointRef,
      makeInstallId: { "unused" })
    #expect(relaunched.export(inputs, writtenAt: Self.now) == .written(sequence: 3))
    let root = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: relaunched.fileURL)) as? [String: Any])
    #expect(root["installId"] as? String == "install-a")
    #expect(root["sequence"] as? Int == 3)

    // An unreadable previous file starts a new installId, which can never
    // read as a regression of the old one.
    try Data("{".utf8).write(to: relaunched.fileURL)
    var afterCorruption = QuotaSnapshotExporter(
      directory: directory, producer: Self.producer, antigravityEndpointRef: Self.endpointRef,
      makeInstallId: { "install-c" })
    #expect(afterCorruption.export(inputs, writtenAt: Self.now) == .written(sequence: 0))
    let fresh = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: afterCorruption.fileURL)) as? [String: Any])
    #expect(fresh["installId"] as? String == "install-c")
  }

  @Test("the write is atomic, mode 0600 in a 0700 directory, and leaves no temporary file")
  func atomicWrite() throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "Alight", directoryHint: .isDirectory)
    var exporter = QuotaSnapshotExporter(
      directory: directory, producer: Self.producer, antigravityEndpointRef: Self.endpointRef)
    #expect(exporter.fileURL.lastPathComponent == "quota-snapshot.v1.json")

    // A symlink planted at the target is replaced, never followed.
    let decoy = root.appending(path: "decoy.json")
    try Data("decoy".utf8).write(to: decoy)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: exporter.fileURL, withDestinationURL: decoy)

    #expect(exporter.export(try Self.observedInputs(), writtenAt: Self.now) == .written(sequence: 0))
    #expect(try String(contentsOf: decoy, encoding: .utf8) == "decoy")
    let attributes = try FileManager.default.attributesOfItem(atPath: exporter.fileURL.path)
    #expect(attributes[.type] as? FileAttributeType == .typeRegular)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["quota-snapshot.v1.json"])
    let written = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: exporter.fileURL)) as? [String: Any])
    #expect(written["schema"] as? String == QuotaSnapshot.schema)

    // A second write replaces the file in place.
    #expect(exporter.export([], writtenAt: Self.now) == .written(sequence: 1))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["quota-snapshot.v1.json"])
  }

  @Test("a development build without a source commit writes nothing")
  func developmentBuildSkips() throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for producer in [nil, QuotaSnapshot.Producer(app: QuotaSnapshot.producerApp, version: "1", build: "1", sourceCommit: "unknown")] {
      var exporter = QuotaSnapshotExporter(directory: directory, producer: producer, antigravityEndpointRef: nil)
      guard case .skipped = exporter.export(try Self.observedInputs(), writtenAt: Self.now) else {
        Issue.record("expected a skipped export")
        return
      }
      #expect(!FileManager.default.fileExists(atPath: exporter.fileURL.path))
    }
  }

  // MARK: Secrets

  @Test("the export holds only domain-separated digests: no token, email, raw account id, or extra field")
  func noSecretFields() throws {
    var claude = try Self.claudeResult(Self.claudeLines)
    claude.observationIdentity = ClaudeAuthStatus.observationIdentity(
      email: "Person@Example.com", orgId: "org-1", subscriptionType: "max")
    let snapshot = Self.snapshot([
      .init(result: try Self.codexResult(), attemptedAt: Self.now, liveCapturedAt: Self.now),
      .init(result: claude, attemptedAt: Self.now, liveCapturedAt: Self.now),
    ])
    let text = String(decoding: try QuotaSnapshotExporter.encode(snapshot), as: UTF8.self).lowercased()
    for forbidden in ["person@example.com", "org-1", "acct-123", "token", "bearer", "cookie", "authorization",
      "password", "secret", "max", claude.observationIdentity!.accountPartition] {
      #expect(!text.contains(forbidden), "\(forbidden)")
    }
    // Fieldbook's `usageAccountRef` vectors, computed with
    // fieldbook/src/quota/provider-usage-derive.mjs.
    #expect(try Self.entry(snapshot, .claude).accountRef
      == "20c7dab6cb1226b72df272f27dc62ca8fe2d011e731abfd37a27986e8b6d54e7")
    #expect(try Self.entry(snapshot, .codex).accountRef
      == "be4db37c85caa25560c5343c88b29119f302b862141a5b56f46289e74af2626f")
  }

  @Test("usageAccountRef matches Fieldbook, including JSON escaping and trimming")
  func usageAccountRefVectors() {
    #expect(UsageAccountRef.digest(
      provider: .codex, organization: " o/\"\\x\u{01}\u{1F}\t ", identifier: "\u{E9}\u{2028}/\u{FC}", kind: .opaque)
      == "13989914aa5db751ca54fd7c486b86c194a95ad467c20d25ed78f1a3a0c41104")
    #expect(UsageAccountRef.digest(provider: .claude, organization: "o", identifier: "  ", kind: .email) == nil)
    #expect(UsageAccountRef.javaScriptJSONString("a\"b\\c\n\u{01}/") == "\"a\\\"b\\\\c\\n\\u0001/\"")
  }

  @Test("Claude auth status yields the account digest only for an identified login")
  func claudeAuthAccountRef() throws {
    let identified = try #require(ClaudeAuthStatus.parse(Data(
      #"{"loggedIn":true,"email":" Person@Example.com ","orgId":"org-1","subscriptionType":"max"}"#.utf8)))
    #expect(identified.accountRef == "20c7dab6cb1226b72df272f27dc62ca8fe2d011e731abfd37a27986e8b6d54e7")
    let anonymous = try #require(ClaudeAuthStatus.parse(Data(#"{"loggedIn":true}"#.utf8)))
    #expect(anonymous.accountRef == nil)
  }
}
