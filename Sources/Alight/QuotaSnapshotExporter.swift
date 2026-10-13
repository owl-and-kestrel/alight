import CryptoKit
import Foundation
import OSLog

// MARK: - Provider-reported quota facts

/// Quota facts exactly as a provider reported them, captured by each client's
/// parser next to the display windows. Display windows are clamped to 0–100,
/// rebased when cached, and may carry invented defaults (a missing reset
/// becomes "now + window"); a report never does. It is the only input to the
/// `ok.alight.quota-snapshot.v1` export (`docs/quota-snapshot-v1.md`).
///
/// A parser returns no report when a raw value cannot be exported honestly
/// (a negative usage, an unparseable reset, a bucket without a cadence). The
/// export then says `failed`/`parse_failed` instead of guessing.
struct QuotaReport: Codable, Equatable, Sendable {
  let groups: [QuotaReportGroup]
}

/// Provider grouping, verbatim. Antigravity reports named groups of buckets;
/// Claude and Codex have one ungrouped list (`providerGroup == nil`).
struct QuotaReportGroup: Codable, Equatable, Sendable {
  let providerGroup: QuotaProviderGroup?
  let windows: [QuotaReportWindow]
}

struct QuotaProviderGroup: Codable, Equatable, Sendable {
  let displayName: String
  let bucketIds: [String]
}

struct QuotaReportWindow: Codable, Equatable, Sendable {
  enum Precision: String, Codable, Sendable {
    /// Whatever the provider printed; no rounding rule is known.
    case unverified
    /// The provider prints `floor(utilization)` as a whole number.
    case floorInteger = "floor_integer"
    case exact
  }

  enum SecondsSource: String, Codable, Sendable {
    /// The provider reported the window length as a number.
    case provider
    /// The length follows from a provider label (`5h`, `weekly`, `session`).
    case label
  }

  /// Window length in whole seconds. Every exported window has one; a bucket
  /// whose length cannot be established is not reported at all.
  let windowSeconds: Int
  let windowSecondsSource: SecondsSource
  /// As reported, before any clamp. May exceed 100 (usage over the limit).
  let usedPercentRaw: Double
  let usedPercentPrecision: Precision
  /// Nil when the provider did not report a reset. Never invented.
  let resetAt: Date?
  let providerBucketId: String?
  /// Claude model scope (`Fable`, `Sonnet`). Always nil inside an
  /// Antigravity group: there the group itself is the scope.
  let scope: UsageScope?
}

/// Closed failure vocabulary of the v1 export.
enum ProviderFailureCode: String, Codable, Sendable {
  case authRequired = "auth_required"
  case network
  case rateLimited = "rate_limited"
  case parseFailed = "parse_failed"
  case refused
  case unknown
}

// MARK: - Fieldbook account reference

/// Fieldbook's `usageAccountRef` (`src/quota/provider-usage-derive.mjs`):
/// sha256 of `JSON.stringify(['ok.fieldbook.usage-account.v1', provider,
/// identifierKind, organization.trim(), identifier])`, where an email
/// identifier is `trim()`med and `toLowerCase()`d and an opaque one only
/// trimmed. The raw identifier never leaves the caller; only this digest is
/// exported.
///
/// The digest is only useful if it is byte-identical to Fieldbook's, so the
/// JavaScript string operations are ported exactly rather than approximated
/// with Foundation: `trim()` removes the ECMAScript WhiteSpace and
/// LineTerminator set (U+FEFF yes, U+0085 no), `toLowerCase()` applies the
/// full Unicode lowercase mapping including the context-dependent final
/// sigma, and neither side normalizes (NFC and NFD spellings of one name give
/// different digests in both). An email containing a code point this runtime's
/// Unicode tables do not assign returns nil: its lowercase form could differ
/// from Fieldbook's (Node's ICU) tables, and an unbound reading is honest
/// where a wrong digest would silently misattribute it.
enum UsageAccountRef {
  static let tag = "ok.fieldbook.usage-account.v1"

  enum IdentifierKind: String {
    case email
    case opaque
  }

  static func digest(provider: Provider, organization: String?, identifier: String?, kind: IdentifierKind) -> String? {
    guard let identifier else { return nil }
    let trimmed = javaScriptTrim(identifier)
    guard !trimmed.isEmpty else { return nil }
    let id: String
    switch kind {
    case .opaque:
      id = trimmed
    case .email:
      guard trimmed.unicodeScalars.allSatisfy({ $0.isASCII || $0.properties.generalCategory != .unassigned }) else {
        return nil
      }
      id = javaScriptLowercase(trimmed)
    }
    let org = javaScriptTrim(organization ?? "")
    let payload = "[" + [tag, provider.rawValue, kind.rawValue, org, id].map(javaScriptJSONString).joined(separator: ",") + "]"
    return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// ECMAScript WhiteSpace plus LineTerminator (ECMA-262 §12.2–12.3), the set
  /// `String.prototype.trim` removes: TAB, VT, FF, ZWNBSP (U+FEFF), every
  /// `Zs` space, LF, CR, U+2028 and U+2029. U+0085 and U+180E are not in it.
  static func isJavaScriptWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
      true
    default:
      false
    }
  }

  /// JavaScript `String.prototype.trim`. Every code point in the set is in
  /// the BMP, so trimming scalars equals trimming UTF-16 code units.
  static func javaScriptTrim(_ value: String) -> String {
    let scalars = value.unicodeScalars
    guard let first = scalars.firstIndex(where: { !isJavaScriptWhitespace($0) }),
      let last = scalars.lastIndex(where: { !isJavaScriptWhitespace($0) }) else {
      return ""
    }
    return String(scalars[first...last])
  }

  /// JavaScript `String.prototype.toLowerCase`: Unicode default case
  /// conversion, every code point's full lowercase mapping, with capital
  /// sigma becoming final `ς` where the Final_Sigma condition holds (Unicode
  /// §3.13, Table 3-17). Swift's `lowercased()` maps code points alone and
  /// would always give `σ`.
  static func javaScriptLowercase(_ value: String) -> String {
    let scalars = Array(value.unicodeScalars)
    var out = String.UnicodeScalarView()
    for (index, scalar) in scalars.enumerated() {
      if scalar.value == 0x03A3, isFinalSigma(at: index, in: scalars) {
        out.append(Unicode.Scalar(0x03C2)!)
      } else {
        out.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
      }
    }
    return String(out)
  }

  /// Before C: a cased letter, then zero or more case-ignorable code points.
  /// After C: not zero or more case-ignorable code points, then a cased letter.
  private static func isFinalSigma(at index: Int, in scalars: [Unicode.Scalar]) -> Bool {
    var before = index - 1
    while before >= 0, scalars[before].properties.isCaseIgnorable { before -= 1 }
    guard before >= 0, scalars[before].properties.isCased else { return false }
    var after = index + 1
    while after < scalars.count, scalars[after].properties.isCaseIgnorable { after += 1 }
    return !(after < scalars.count && scalars[after].properties.isCased)
  }

  /// A string literal byte-identical to JavaScript's `JSON.stringify`: only
  /// `"`, `\` and C0 controls are escaped, with lowercase `\u00xx`.
  static func javaScriptJSONString(_ value: String) -> String {
    var out = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case _ where scalar.value < 0x20:
        out += String(format: "\\u%04x", scalar.value)
      default:
        out.unicodeScalars.append(scalar)
      }
    }
    return out + "\""
  }
}

// MARK: - Snapshot document

/// The closed `ok.alight.quota-snapshot.v1` document. Every key is always
/// present; absent values are written as `null`, never omitted, because the
/// reader (Fieldbook `checkAlightSnapshot`) requires each key.
struct QuotaSnapshot: Encodable, Equatable {
  static let schema = "ok.alight.quota-snapshot.v1"
  static let producerApp = "com.owlandkestrel.alight"

  struct Producer: Encodable, Equatable {
    let app: String
    let version: String
    let build: String
    let sourceCommit: String
  }

  struct Failure: Encodable, Equatable {
    let code: ProviderFailureCode
    let needsAuth: Bool
  }

  struct Scope: Encodable, Equatable {
    let kind: String
    let key: String
    let displayName: String
  }

  struct Window: Encodable, Equatable {
    let windowId: String
    let cadence: String?
    let usedPercentRaw: Double
    let usedPercentPrecision: String
    let resetAt: String?
    let resetSource: String
    let windowSeconds: Int?
    let windowSecondsSource: String
    let providerBucketId: String?
    let scope: Scope?

    enum CodingKeys: String, CodingKey {
      case windowId, cadence, usedPercentRaw, usedPercentPrecision, resetAt, resetSource
      case windowSeconds, windowSecondsSource, providerBucketId, scope
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(windowId, forKey: .windowId)
      try c.encode(cadence, forKey: .cadence)
      try c.encode(usedPercentRaw, forKey: .usedPercentRaw)
      try c.encode(usedPercentPrecision, forKey: .usedPercentPrecision)
      try c.encode(resetAt, forKey: .resetAt)
      try c.encode(resetSource, forKey: .resetSource)
      try c.encode(windowSeconds, forKey: .windowSeconds)
      try c.encode(windowSecondsSource, forKey: .windowSecondsSource)
      try c.encode(providerBucketId, forKey: .providerBucketId)
      try c.encode(scope, forKey: .scope)
    }
  }

  struct Group: Encodable, Equatable {
    let providerGroup: QuotaProviderGroup?
    let windows: [Window]

    enum CodingKeys: String, CodingKey { case providerGroup, windows }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(providerGroup, forKey: .providerGroup)
      try c.encode(windows, forKey: .windows)
    }
  }

  enum Status: String, Encodable {
    case observed
    case failed
    case signedOut = "signed_out"
    case refused
    case deferred
  }

  struct ProviderEntry: Encodable, Equatable {
    let provider: Provider
    let status: Status
    let attemptedAt: String
    let capturedAt: String?
    let readingSource: String
    let cacheAgeSeconds: Double?
    let accountRef: String?
    let endpointRef: String?
    let failure: Failure?
    let groups: [Group]

    enum CodingKeys: String, CodingKey {
      case provider, status, attemptedAt, capturedAt, readingSource, cacheAgeSeconds
      case accountRef, endpointRef, failure, groups
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(provider, forKey: .provider)
      try c.encode(status, forKey: .status)
      try c.encode(attemptedAt, forKey: .attemptedAt)
      try c.encode(capturedAt, forKey: .capturedAt)
      try c.encode(readingSource, forKey: .readingSource)
      try c.encode(cacheAgeSeconds, forKey: .cacheAgeSeconds)
      try c.encode(accountRef, forKey: .accountRef)
      try c.encode(endpointRef, forKey: .endpointRef)
      try c.encode(failure, forKey: .failure)
      try c.encode(groups, forKey: .groups)
    }
  }

  let schema: String
  let producer: Producer
  let installId: String
  let sequence: Int
  let writtenAt: String
  let providers: [ProviderEntry]
}

// MARK: - Exporter

/// Writes `quota-snapshot.v1.json` after every refresh, failures included, so
/// Fieldbook and the desk can read quota pace without touching Alight's
/// private `usage-cache.json` or any credential.
///
/// - Location: `~/Library/Application Support/Alight/quota-snapshot.v1.json`,
///   beside the cache (design r2 §4.1). Application Support is not synced by
///   iCloud Drive.
/// - Atomic: a same-directory temporary file is written, `fsync`ed, renamed
///   over the target, and the directory is `fsync`ed. Mode 0600, directory 0700.
///   `written` means all of that succeeded; a failed directory sync is
///   reported, not ignored.
/// - `installId` is random, not an identity. `sequence` increases by one per
///   write. Both resume from Alight's own previous snapshot file, so a relaunch
///   never regresses the sequence; an unreadable file, or one whose sequence
///   is not a safe integer, starts a new installId, as does reaching
///   `maximumSequence`.
/// - A provider whose facts fail the contract's ranges is exported as
///   `failed`/`parse_failed`. Nothing is clamped or guessed.
/// - A build without a 40-hex source commit (an unbundled development run)
///   writes nothing: the reader would refuse the whole file.
struct QuotaSnapshotExporter {
  static let fileName = "quota-snapshot.v1.json"
  /// Fieldbook's reader refuses larger files (design r2 §4.1).
  static let maximumBytes = 256 * 1024
  /// JavaScript `Number.MAX_SAFE_INTEGER`. Fieldbook refuses a `sequence`
  /// above it, so the exporter never writes one: at the bound it starts a new
  /// `installId` at 0, which the reader cannot mistake for a regression.
  static let maximumSequence = 9_007_199_254_740_991

  struct Input {
    let result: ProviderResult
    /// When this refresh asked the provider (or decided not to, if deferred).
    let attemptedAt: Date
    /// Completion time of a live request this refresh. Nil when deferred.
    let liveCapturedAt: Date?
  }

  enum Outcome: Equatable {
    case written(sequence: Int)
    case skipped(String)
    case failed(String)
  }

  private static let logger = Logger(subsystem: "com.owlandkestrel.alight", category: "quota-snapshot")

  let fileURL: URL
  let producer: QuotaSnapshot.Producer?
  let antigravityEndpointRef: String?
  /// Test seam for the durability step; `.system` in the app.
  var directorySync: DirectorySync = .system
  private let makeInstallId: () -> String
  private var state: (installId: String, nextSequence: Int)?

  init(
    directory: URL = QuotaSnapshotExporter.defaultDirectory,
    producer: QuotaSnapshot.Producer? = QuotaSnapshotExporter.bundleProducer(),
    antigravityEndpointRef: String? = AntigravityUsageSource.cacheIdentity(),
    makeInstallId: @escaping () -> String = { UUID().uuidString.lowercased() }
  ) {
    self.fileURL = directory.appending(path: Self.fileName)
    self.producer = producer
    self.antigravityEndpointRef = antigravityEndpointRef
    self.makeInstallId = makeInstallId
  }

  /// Builds and atomically writes one snapshot. Never throws: the export is
  /// observational and must never hold up the menu.
  @discardableResult
  mutating func export(_ inputs: [Input], writtenAt: Date = Date()) -> Outcome {
    guard let producer, Self.isValidProducer(producer) else {
      Self.logger.info("quota snapshot skipped: producer metadata unavailable (development build)")
      return .skipped("producer metadata unavailable")
    }
    let (installId, sequence) = nextIdentity()
    state = (installId, sequence + 1)
    let snapshot = Self.snapshot(
      inputs, producer: producer, installId: installId, sequence: sequence,
      writtenAt: writtenAt, antigravityEndpointRef: antigravityEndpointRef
    )
    do {
      let data = try Self.encode(snapshot)
      guard data.count <= Self.maximumBytes else {
        Self.logger.error("quota snapshot not written: \(data.count, privacy: .public) bytes exceeds the reader bound")
        return .failed("snapshot exceeds \(Self.maximumBytes) bytes")
      }
      try Self.writeAtomically(data, to: fileURL, directorySync: directorySync)
      return .written(sequence: sequence)
    } catch {
      Self.logger.error("quota snapshot write not completed: \(String(describing: error), privacy: .public)")
      return .failed(String(describing: error))
    }
  }

  private mutating func nextIdentity() -> (String, Int) {
    if let state, state.nextSequence <= Self.maximumSequence {
      return (state.installId, state.nextSequence)
    }
    if state == nil, let previous = Self.readPreviousIdentity(at: fileURL), previous.sequence < Self.maximumSequence {
      return (previous.installId, previous.sequence + 1)
    }
    return (makeInstallId(), 0)
  }

  // MARK: Mapping

  static func snapshot(
    _ inputs: [Input],
    producer: QuotaSnapshot.Producer,
    installId: String,
    sequence: Int,
    writtenAt: Date,
    antigravityEndpointRef: String?
  ) -> QuotaSnapshot {
    let providers = inputs
      .sorted { $0.result.provider.rawValue < $1.result.provider.rawValue }
      .map { providerEntry($0, antigravityEndpointRef: antigravityEndpointRef) }
    return QuotaSnapshot(
      schema: QuotaSnapshot.schema,
      producer: producer,
      installId: installId,
      sequence: sequence,
      writtenAt: timestamp(writtenAt),
      providers: providers
    )
  }

  static func providerEntry(_ input: Input, antigravityEndpointRef: String?) -> QuotaSnapshot.ProviderEntry {
    let result = input.result
    let endpointRef = result.provider == .antigravity ? antigravityEndpointRef.flatMap(validDigest) : nil
    let accountRef = result.accountRef.flatMap(validDigest)
    let cacheAge = result.cacheAgeSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }

    func unavailable(_ status: QuotaSnapshot.Status, _ failure: QuotaSnapshot.Failure?) -> QuotaSnapshot.ProviderEntry {
      QuotaSnapshot.ProviderEntry(
        provider: result.provider, status: status, attemptedAt: timestamp(input.attemptedAt),
        capturedAt: nil, readingSource: "live", cacheAgeSeconds: cacheAge,
        accountRef: accountRef, endpointRef: endpointRef, failure: failure, groups: []
      )
    }

    // A current attempt that says sign-in is required is exported as such even
    // when the menu shows a last-good cached reading: the cache is history,
    // and Fieldbook must keep the provider unknown with `auth_required`
    // rather than read it as available (v1 rules 3 and 4). The menu keeps
    // showing the cached windows with its sign-in prompt; only the export
    // differs.
    let authRequired = result.needsAuth || result.source == ClaudeUsageClient.signedOutSource
    guard result.ok, !result.windows.isEmpty, !authRequired else {
      if result.source == "deferred" {
        return unavailable(.deferred, result.needsAuth ? .init(code: .authRequired, needsAuth: true) : nil)
      }
      if result.source == ClaudeUsageClient.refusedSource {
        return unavailable(.refused, .init(code: .refused, needsAuth: false))
      }
      if authRequired {
        return unavailable(.signedOut, .init(code: .authRequired, needsAuth: true))
      }
      return unavailable(.failed, .init(code: result.failureCode ?? .unknown, needsAuth: false))
    }

    let cached = result.source == "cached"
    let capturedAt = cached ? result.capturedAt : input.liveCapturedAt
    guard let capturedAt, capturedAt.timeIntervalSince1970.isFinite,
      let report = result.quotaReport,
      let groups = exportGroups(report, provider: result.provider) else {
      return unavailable(.failed, .init(code: .parseFailed, needsAuth: false))
    }
    return QuotaSnapshot.ProviderEntry(
      provider: result.provider, status: .observed, attemptedAt: timestamp(input.attemptedAt),
      capturedAt: timestamp(capturedAt), readingSource: cached ? "cached" : "live",
      cacheAgeSeconds: cached ? cacheAge : nil,
      accountRef: accountRef, endpointRef: endpointRef, failure: nil, groups: groups
    )
  }

  /// Maps a report to export groups, or nil when any value falls outside the
  /// contract. These checks mirror Fieldbook's `checkAlightSnapshot` and the
  /// conditions under which `normalizeAlightQuotaSnapshot` would refuse the
  /// whole file, so one bad provider can only fail itself.
  static func exportGroups(_ report: QuotaReport, provider: Provider) -> [QuotaSnapshot.Group]? {
    guard !report.groups.isEmpty else { return nil }
    var normalizedIds: Set<String> = []
    var groups: [QuotaSnapshot.Group] = []
    for group in report.groups {
      if provider == .antigravity {
        guard let named = group.providerGroup, isText(named.displayName), named.bucketIds.allSatisfy(isText) else {
          return nil
        }
      } else if group.providerGroup != nil {
        return nil
      }
      var windows: [QuotaSnapshot.Window] = []
      for window in group.windows {
        guard let exported = exportWindow(window, grouped: group.providerGroup != nil) else { return nil }
        // Fieldbook's reader keys each window by windowId plus its scope (the
        // group name slug for non-Gemini Antigravity groups). Duplicates would
        // make it refuse the whole snapshot.
        let scopeKey: String? = if let named = group.providerGroup {
          fieldbookIsPrimaryGroup(named.displayName) ? nil : fieldbookGroupSlug(named.displayName)
        } else {
          exported.scope?.key
        }
        let normalizedId = scopeKey.map { "\(exported.windowId):\($0)" } ?? exported.windowId
        guard normalizedIds.insert(normalizedId).inserted else { return nil }
        windows.append(exported)
      }
      groups.append(QuotaSnapshot.Group(providerGroup: group.providerGroup, windows: windows))
    }
    // An observed provider needs at least one window to be usable.
    guard !normalizedIds.isEmpty else { return nil }
    return groups
  }

  static func exportWindow(_ window: QuotaReportWindow, grouped: Bool) -> QuotaSnapshot.Window? {
    let raw = window.usedPercentRaw
    guard raw.isFinite, raw >= 0 else { return nil }
    // A whole-percent precision needs a whole number; above 100 the reader
    // classifies the window itself.
    if window.usedPercentPrecision == .floorInteger, raw <= 100, raw.rounded(.towardZero) != raw { return nil }
    guard window.windowSeconds > 0, window.windowSeconds <= 9_007_199_254_740_991 else { return nil }
    if let bucket = window.providerBucketId, !isText(bucket) { return nil }
    if let scope = window.scope {
      guard !grouped, ["model", "group"].contains(scope.kind), isText(scope.key), isText(scope.displayName) else {
        return nil
      }
    }
    var resetAt: String?
    if let date = window.resetAt {
      guard let text = boundedTimestamp(date) else { return nil }
      resetAt = text
    }
    let (windowId, cadence) = windowIdentity(seconds: window.windowSeconds)
    return QuotaSnapshot.Window(
      windowId: windowId,
      cadence: cadence,
      usedPercentRaw: raw,
      usedPercentPrecision: window.usedPercentPrecision.rawValue,
      resetAt: resetAt,
      resetSource: resetAt == nil ? "unknown" : "provider",
      windowSeconds: window.windowSeconds,
      windowSecondsSource: window.windowSecondsSource.rawValue,
      providerBucketId: window.providerBucketId,
      scope: window.scope.map { QuotaSnapshot.Scope(kind: $0.kind, key: $0.key, displayName: $0.displayName) }
    )
  }

  /// Fieldbook's provider-usage convention: `session` is 18000 s, `week`
  /// 604800 s, anything else `window_<n>s` with no named cadence.
  static func windowIdentity(seconds: Int) -> (String, String?) {
    switch seconds {
    case 18_000: ("session", "5h")
    case 604_800: ("week", "weekly")
    default: ("window_\(seconds)s", nil)
    }
  }

  /// Fieldbook `isAntigravityPrimaryGroup` (`src/quota/pools.mjs`).
  static func fieldbookIsPrimaryGroup(_ displayName: String) -> Bool {
    UsageAccountRef.javaScriptLowercase(displayName).contains("gemini")
  }

  /// Fieldbook's group scope key: lowercase, each run of characters outside
  /// `a-z0-9` replaced by `_` (`src/quota/alight-snapshot.mjs`).
  static func fieldbookGroupSlug(_ displayName: String) -> String {
    var slug = ""
    var inRun = false
    for scalar in UsageAccountRef.javaScriptLowercase(displayName).unicodeScalars {
      if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
        slug.unicodeScalars.append(scalar)
        inRun = false
      } else if !inRun {
        slug.append("_")
        inRun = true
      }
    }
    return slug
  }

  /// Fieldbook `isText`: non-empty after JavaScript `trim()`. Foundation's
  /// whitespace set differs (it keeps U+FEFF), and a text field Fieldbook
  /// finds blank would make it refuse the whole file.
  private static func isText(_ value: String) -> Bool {
    !UsageAccountRef.javaScriptTrim(value).isEmpty
  }

  private static func isLowerHex(_ value: String, count: Int) -> Bool {
    value.count == count && value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
  }

  /// `accountRef` and `endpointRef` are 64-hex digests or null.
  private static func validDigest(_ value: String) -> String? {
    isLowerHex(value, count: 64) ? value : nil
  }

  static func isValidProducer(_ producer: QuotaSnapshot.Producer) -> Bool {
    isText(producer.app) && isText(producer.version) && isText(producer.build)
      && isLowerHex(producer.sourceCommit, count: 40)
  }

  // MARK: Time

  /// UTC with milliseconds, e.g. `2026-10-13T02:35:25.123Z`.
  static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  /// A reset outside years 1970–9999 cannot be written as the reader's ISO time.
  private static func boundedTimestamp(_ date: Date) -> String? {
    let seconds = date.timeIntervalSince1970
    guard seconds.isFinite, seconds >= 0, seconds < 253_402_300_800 else { return nil }
    return timestamp(date)
  }

  // MARK: Producer

  static func bundleProducer(_ bundle: Bundle = .main) -> QuotaSnapshot.Producer? {
    guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
      let commit = bundle.object(forInfoDictionaryKey: "AlightSourceCommit") as? String else {
      return nil
    }
    return QuotaSnapshot.Producer(app: QuotaSnapshot.producerApp, version: version, build: build, sourceCommit: commit)
  }

  // MARK: File I/O

  static var defaultDirectory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
    return base.appending(path: "Alight", directoryHint: .isDirectory)
  }

  static func encode(_ snapshot: QuotaSnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.nonConformingFloatEncodingStrategy = .throw
    return try encoder.encode(snapshot)
  }

  enum WriteError: Error, Equatable {
    /// The write failed before the rename; the previous file is unchanged.
    case posix(String, Int32)
    /// The new file was renamed into place, so readers may already see it,
    /// but the directory entry could not be synced: the replacement may not
    /// survive a crash. Reported, never ignored, so `written` always means
    /// durable completion.
    case directoryNotSynced(String, Int32)
  }

  /// The two POSIX calls that make the rename durable. A seam only so tests
  /// can prove a failure is reported; production uses `.system`.
  struct DirectorySync: Sendable {
    /// Opens the directory for `fsync`; returns a descriptor or -1 with `errno`.
    var open: @Sendable (String) -> Int32
    /// Returns 0, or -1 with `errno`.
    var fsync: @Sendable (Int32) -> Int32

    static let system = DirectorySync(
      open: { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) },
      fsync: { Darwin.fsync($0) }
    )
  }

  /// Temporary file in the target directory, `fsync`, `rename`, then `fsync`
  /// the directory, so a reader sees either the previous or the new complete
  /// file. `O_EXCL | O_NOFOLLOW` refuses a planted temporary path or symlink.
  /// Throws `directoryNotSynced` when the final directory sync fails.
  static func writeAtomically(_ data: Data, to url: URL, directorySync: DirectorySync = .system) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

    let temporary = directory.appending(path: ".\(fileName).\(UUID().uuidString).tmp")
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw WriteError.posix("open", errno) }
    var renamed = false
    defer {
      if !renamed { unlink(temporary.path) }
    }
    do {
      defer { close(fd) }
      guard fchmod(fd, 0o600) == 0 else { throw WriteError.posix("fchmod", errno) }
      try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
          let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
          if written < 0 {
            if errno == EINTR { continue }
            throw WriteError.posix("write", errno)
          }
          offset += written
        }
      }
      guard fsync(fd) == 0 else { throw WriteError.posix("fsync", errno) }
    }
    guard rename(temporary.path, url.path) == 0 else { throw WriteError.posix("rename", errno) }
    renamed = true
    // Durability of the rename itself; the file content is already synced.
    let directoryFd = directorySync.open(directory.path)
    guard directoryFd >= 0 else { throw WriteError.directoryNotSynced("open", errno) }
    defer { close(directoryFd) }
    while directorySync.fsync(directoryFd) != 0 {
      let code = errno
      if code != EINTR { throw WriteError.directoryNotSynced("fsync", code) }
    }
  }

  /// Reads `installId` and `sequence` from Alight's own previous snapshot.
  /// Bounded and symlink-refusing; any doubt starts a new installId, which
  /// can never look like a sequence regression.
  static func readPreviousIdentity(at url: URL) -> (installId: String, sequence: Int)? {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maximumBytes else {
      return nil
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while data.count <= maximumBytes {
      let count = read(fd, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { break }
      data.append(contentsOf: buffer[0..<count])
    }
    guard data.count <= maximumBytes,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["schema"] as? String == QuotaSnapshot.schema,
      let installId = object["installId"] as? String, isText(installId),
      let number = object["sequence"] as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    // A value that is not an exact non-negative safe integer (negative,
    // fractional, huge, or past the bound) is corrupt: start a new installId.
    let sequence = number.int64Value
    guard Double(sequence) == number.doubleValue, sequence >= 0, sequence <= Int64(maximumSequence) else { return nil }
    return (installId, Int(sequence))
  }
}
