import Foundation
import Testing
@testable import Alight

/// Regressions for the independent review of the first exporter candidate
/// (cached capture time, a cache hiding a current sign-in failure, digest
/// normalization, and the safe-integer sequence bound). Each expectation is
/// a Fieldbook v1 contract property; this suite uses only the exporter's
/// original API so it also compiles against, and fails on, that candidate.
@Suite("Quota snapshot contract regressions")
struct QuotaSnapshotContractRegressionTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)
  private static let producer = QuotaSnapshot.Producer(
    app: QuotaSnapshot.producerApp, version: "1.3.3", build: "42", sourceCommit: String(repeating: "ab", count: 20))

  private static func liveResult(_ provider: Provider) -> ProviderResult {
    let seconds = provider == .antigravity ? 18_000 : 604_800
    let resetAt = now.addingTimeInterval(3 * 3600)
    let window = PressureMath.window(
      provider: provider, speed: .slow, usedPercent: 30, resetAt: resetAt,
      limitWindowSeconds: TimeInterval(seconds), now: now)
    var result = ProviderResult(provider: provider, ok: true, source: "live", error: nil, windows: [window])
    let group: QuotaProviderGroup? = provider == .antigravity
      ? QuotaProviderGroup(displayName: "Gemini Models", bucketIds: ["gemini-5h"]) : nil
    result.quotaReport = QuotaReport(groups: [QuotaReportGroup(providerGroup: group, windows: [
      QuotaReportWindow(
        windowSeconds: seconds, windowSecondsSource: .provider, usedPercentRaw: 30, usedPercentPrecision: .unverified,
        resetAt: resetAt, providerBucketId: provider == .antigravity ? "gemini-5h" : "primary_window", scope: nil),
    ])])
    return result
  }

  private static func entry(_ result: ProviderResult, attemptedAt: Date, liveCapturedAt: Date?) -> QuotaSnapshot.ProviderEntry {
    QuotaSnapshotExporter.providerEntry(
      .init(result: result, attemptedAt: attemptedAt, liveCapturedAt: liveCapturedAt),
      antigravityEndpointRef: String(repeating: "e", count: 64))
  }

  private static func emitFixture(_ name: String, _ inputs: [QuotaSnapshotExporter.Input], writtenAt: Date) throws {
    guard let directory = ProcessInfo.processInfo.environment["ALIGHT_QUOTA_SNAPSHOT_FIXTURE_DIR"], !directory.isEmpty else {
      return
    }
    let snapshot = QuotaSnapshotExporter.snapshot(
      inputs, producer: producer, installId: "install-1", sequence: 7, writtenAt: writtenAt,
      antigravityEndpointRef: String(repeating: "e", count: 64))
    try QuotaSnapshotExporter.encode(snapshot).write(to: URL(fileURLWithPath: directory).appending(path: "\(name).json"))
  }

  private static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "alight-quota-regression-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  // MARK: Capture time (review F1)

  @Test("a cached reading exports the provider's capture time and age, not the refresh completion")
  func cachedCaptureIsProviderCompletion() throws {
    // The provider answered at 08:00:00.125; the refresh finished (and
    // reconciled) two minutes later, after the slowest provider.
    let providerCompleted = Self.now.addingTimeInterval(0.125)
    let refreshCompleted = Self.now.addingTimeInterval(120)
    var live = Self.liveResult(.codex)
    live.capturedAt = providerCompleted
    var cache = UsageResultCache(persistenceURL: nil)
    _ = cache.reconcile(live, now: refreshCompleted)

    let later = Self.now.addingTimeInterval(901)
    let failed = ProviderResult.failure(.codex, source: "error", error: "x", failureCode: .network)
    let cached = cache.reconcile(failed, now: later)
    #expect(cached.source == "cached")
    #expect(cached.capturedAt == providerCompleted)
    #expect(cached.cacheAgeSeconds == 900.875)

    let liveEntry = Self.entry(live, attemptedAt: Self.now, liveCapturedAt: providerCompleted)
    // Production passes this failed poll's own completion as liveCapturedAt;
    // a cached reading must ignore it.
    let cachedEntry = Self.entry(cached, attemptedAt: later, liveCapturedAt: later)
    #expect(liveEntry.capturedAt == "2027-01-15T08:00:00.125Z")
    #expect(cachedEntry.status == .observed)
    #expect(cachedEntry.readingSource == "cached")
    #expect(cachedEntry.capturedAt == liveEntry.capturedAt)
    #expect(cachedEntry.cacheAgeSeconds == 900.875)
    try Self.emitFixture("cached-provider-capture", [.init(result: cached, attemptedAt: later, liveCapturedAt: later)], writtenAt: later)
  }

  @Test("the provider's capture time survives a relaunch at millisecond precision")
  func cachedCaptureSurvivesRelaunch() throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "usage-cache.json")
    let providerCompleted = Self.now.addingTimeInterval(0.125)
    var live = Self.liveResult(.codex)
    live.capturedAt = providerCompleted
    var first = UsageResultCache(persistenceURL: url)
    _ = first.reconcile(live, now: Self.now.addingTimeInterval(120))

    var relaunched = UsageResultCache(persistenceURL: url)
    let later = Self.now.addingTimeInterval(600)
    let cached = relaunched.reconcile(.failure(.codex, source: "error", error: "x"), now: later)
    #expect(cached.capturedAt == providerCompleted)
    #expect(cached.cacheAgeSeconds == 599.875)
    #expect(Self.entry(cached, attemptedAt: later, liveCapturedAt: later).capturedAt == "2027-01-15T08:00:00.125Z")
  }

  // MARK: Sign-in state over a cache (review F2)

  @Test("a current sign-in failure is exported as signed_out even when a cached reading is shown",
    arguments: [Provider.codex, .antigravity])
  func signedOutOverCache(provider: Provider) throws {
    var cache = UsageResultCache(persistenceURL: nil, antigravitySourceIdentity: String(repeating: "e", count: 64))
    var live = Self.liveResult(provider)
    live.capturedAt = Self.now
    _ = cache.reconcile(live, now: Self.now)

    let later = Self.now.addingTimeInterval(60)
    let signedOut = ProviderResult.failure(
      provider, source: "error", error: "sign in again", needsAuth: true, failureCode: .authRequired)
    let shown = cache.reconcile(signedOut, now: later)
    // The menu still shows the last-good windows, with its sign-in prompt.
    #expect(shown.ok)
    #expect(shown.source == "cached")
    #expect(shown.needsAuth)
    #expect(!shown.windows.isEmpty)

    let entry = Self.entry(shown, attemptedAt: later, liveCapturedAt: later)
    #expect(entry.status == .signedOut)
    #expect(entry.failure == .init(code: .authRequired, needsAuth: true))
    #expect(entry.capturedAt == nil)
    #expect(entry.groups.isEmpty)
    #expect(entry.readingSource == "live")
    try Self.emitFixture(
      "signedout-cached-\(provider.rawValue)", [.init(result: shown, attemptedAt: later, liveCapturedAt: later)],
      writtenAt: later)
  }

  // MARK: Digest normalization (review N1)

  /// Expected values are Fieldbook's own `usageAccountRef`
  /// (`src/quota/provider-usage-derive.mjs` at 20bb37d8), computed in Node
  /// 22 (Unicode 16.0): JavaScript `trim()` and `toLowerCase()`, no
  /// normalization.
  private static let fieldbookVectors: [(Provider, String?, String, UsageAccountRef.IdentifierKind, String)] = [
    (.claude, "org-1", " Person@Example.com ", .email, "20c7dab6cb1226b72df272f27dc62ca8fe2d011e731abfd37a27986e8b6d54e7"),
    (.claude, "\u{FEFF}org-1\u{FEFF}", "\u{FEFF}Person@Example.com\u{FEFF}", .email, "20c7dab6cb1226b72df272f27dc62ca8fe2d011e731abfd37a27986e8b6d54e7"),
    (.claude, "\u{85}org-1\u{85}", "\u{85}Person@Example.com\u{85}", .email, "4ae0121e2faf0023d70553d5e3fdec03ebdde065f16718e8adf625cb5c6b4769"),
    (.claude, "\u{3000}\u{2028}org\u{2029}\u{A0}", "\u{1680}\u{2000}\u{200A}\u{202F}\u{205F}\u{B}\u{C}A@B.C\u{9}\u{D}\u{A}", .email, "a697816d3d90e46677db42d1ca2b98d9eeda505916f999b8fe9d96a11f9da39d"),
    (.claude, "\u{180E}org\u{200B}", "\u{180E}A@B.C\u{200B}", .email, "893ed588836ab8bb86e8203a672d956d7b601962b68691fa778ec59144aab132"),
    (.claude, "org", "\u{39F}\u{394}\u{3A5}\u{3A3}\u{3A3}\u{395}\u{3A5}\u{3A3}@Example.com", .email, "35e04a15219ec05f87a4e05d4678252bf0893c2552e17a6d22becb9470d60ec3"),
    (.claude, "org", "\u{3A3}@x", .email, "a6b2399b3387dcb076ad93ff3348027918561daefa5284495120f1addcfa9d47"),
    (.claude, "org", "A\u{3A3}.b", .email, "5359fcdf79fd4e8394c58b2acc97bc0514af82eb14ed05cc62174e9b854d2b29"),
    (.claude, "org", "A\u{3A3}\u{301}", .email, "5f23ab3e6e051245e744544d05cf0e236a5fb46fe20d3ecef0ee16819e5999c5"),
    (.claude, "org", "\u{130}STANBUL@Example.com", .email, "7288dfbe09b2c01fc2afcbb559352ab46338a15e805f83a47506456a0dcfae6c"),
    (.claude, "org", "\u{1E9E}\u{212A}\u{2126}@X", .email, "53411f2478df87e9797ae50a71f3d075c117ee34073dab34409a589cba5f30a2"),
    (.claude, "org", "Cafe\u{301}@X", .email, "95fd604fce0ba05ae3c49ba68fb687232c674f8f918f30e6744188f55758450e"),
    (.claude, "org", "Caf\u{E9}@X", .email, "eeff73135d9894b86d4f278fe6dad778506b40d73bf74fd5a3db07a0ec98107c"),
    (.claude, "org", "\u{FF21}\u{FF22}\u{FF23}@\u{FF38}", .email, "b0221a1ecd09e7d52bcc7e8cb22a3bdd07cdab9f165fffbc9bf232068c2f5e64"),
    (.claude, "org", "\u{13A0}\u{13F5}@X", .email, "41b6e7bf95a688dc11346573a45787dd20fb7fbc5f747830f14a15be54d3f09b"),
    (.claude, "org", "\u{10400}\u{1E900}@X", .email, "29ea1210063eb9fede2b534a2ebb6504932a65ff7403ae569a0e5643c0db9ea2"),
    (.codex, nil, "\u{FEFF}Acct-123\u{85}", .opaque, "ef17aee9e06aeffcfdf893106557b98d84839d5fed5083848bf27a4fcb9a6f42"),
    (.codex, "", " \u{C0}B\u{3000}", .opaque, "a4bb0a032ee08860a80cc3436d179cac5688b390952ee203ca5e11e1a80f72a6"),
  ]

  @Test("accountRef equals Fieldbook's digest for JavaScript-only whitespace, final sigma, and unnormalized input")
  func accountRefMatchesFieldbookUnicode() throws {
    var actual: [[String: String]] = []
    for (index, vector) in Self.fieldbookVectors.enumerated() {
      let digest = UsageAccountRef.digest(
        provider: vector.0, organization: vector.1, identifier: vector.2, kind: vector.3)
      #expect(digest == vector.4, "vector \(index)")
      actual.append([
        "provider": vector.0.rawValue, "organization": vector.1 ?? "", "identifier": vector.2,
        "identifierKind": vector.3.rawValue, "actualSwift": digest ?? "null",
      ])
    }
    // A whitespace-only identifier in the JavaScript sense is no identity.
    #expect(UsageAccountRef.digest(provider: .claude, organization: "o", identifier: "\u{FEFF}\u{3000}", kind: .email) == nil)
    if let directory = ProcessInfo.processInfo.environment["ALIGHT_QUOTA_SNAPSHOT_FIXTURE_DIR"], !directory.isEmpty {
      try JSONSerialization.data(withJSONObject: actual, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: directory).appending(path: "digests.vectors"))
    }
  }

  @Test("a name Fieldbook's trim() finds blank is refused for that provider, not written for the reader to reject")
  func javaScriptBlankTextRefused() {
    let window = QuotaReportWindow(
      windowSeconds: 18_000, windowSecondsSource: .label, usedPercentRaw: 1,
      usedPercentPrecision: .unverified, resetAt: nil, providerBucketId: "\u{FEFF}", scope: nil)
    #expect(QuotaSnapshotExporter.exportWindow(window, grouped: true) == nil)
    let named = QuotaReport(groups: [QuotaReportGroup(
      providerGroup: .init(displayName: "\u{FEFF}\u{3000}", bucketIds: ["b"]),
      windows: [QuotaReportWindow(
        windowSeconds: 18_000, windowSecondsSource: .label, usedPercentRaw: 1,
        usedPercentPrecision: .unverified, resetAt: nil, providerBucketId: "b", scope: nil)])])
    #expect(QuotaSnapshotExporter.exportGroups(named, provider: .antigravity) == nil)
  }

  // MARK: Sequence bound (review N2)

  private static func seed(_ directory: URL, sequence: String, installId: String = "install-old") throws {
    let text = """
      {"schema":"ok.alight.quota-snapshot.v1","installId":"\(installId)","sequence":\(sequence),"writtenAt":"2027-01-15T08:00:00.000Z","producer":{"app":"com.owlandkestrel.alight","version":"1","build":"1","sourceCommit":"\(String(repeating: "ab", count: 20))"},"providers":[]}
      """
    try Data(text.utf8).write(to: directory.appending(path: QuotaSnapshotExporter.fileName))
  }

  private static func written(_ exporter: QuotaSnapshotExporter) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: exporter.fileURL)) as? [String: Any])
  }

  @Test("the sequence never passes Number.MAX_SAFE_INTEGER: at the bound a new installId starts at 0")
  func sequenceStaysSafe() throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Self.seed(directory, sequence: "9007199254740990")
    var ids = ["install-new"]
    var exporter = QuotaSnapshotExporter(
      directory: directory, producer: Self.producer, antigravityEndpointRef: nil, makeInstallId: { ids.removeFirst() })

    #expect(exporter.export([], writtenAt: Self.now) == .written(sequence: 9_007_199_254_740_991))
    #expect(try Self.written(exporter)["installId"] as? String == "install-old")
    if let fixtures = ProcessInfo.processInfo.environment["ALIGHT_QUOTA_SNAPSHOT_FIXTURE_DIR"], !fixtures.isEmpty {
      try Data(contentsOf: exporter.fileURL).write(to: URL(fileURLWithPath: fixtures).appending(path: "sequence-max.json"))
    }
    #expect(exporter.export([], writtenAt: Self.now) == .written(sequence: 0))
    if let fixtures = ProcessInfo.processInfo.environment["ALIGHT_QUOTA_SNAPSHOT_FIXTURE_DIR"], !fixtures.isEmpty {
      try Data(contentsOf: exporter.fileURL).write(to: URL(fileURLWithPath: fixtures).appending(path: "sequence-rotated.json"))
    }
    let rotated = try Self.written(exporter)
    #expect(rotated["installId"] as? String == "install-new")
    #expect(rotated["sequence"] as? Int == 0)
    #expect(exporter.export([], writtenAt: Self.now) == .written(sequence: 1))
  }

  @Test("a previous sequence that is not a safe non-negative integer starts a new installId",
    arguments: ["9007199254740991", "9007199254740992", "9007199254740993", "9223372036854775807",
      "18446744073709551615", "123456789012345678901234567890", "1e300", "-1", "1.5", "true", "\"7\"", "null"])
  func corruptPreviousSequence(sequence: String) throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Self.seed(directory, sequence: sequence)
    var exporter = QuotaSnapshotExporter(
      directory: directory, producer: Self.producer, antigravityEndpointRef: nil, makeInstallId: { "install-new" })
    #expect(exporter.export([], writtenAt: Self.now) == .written(sequence: 0))
    #expect(try Self.written(exporter)["installId"] as? String == "install-new")
  }
}
