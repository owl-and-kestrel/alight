import Foundation
import Observation

/// What a card element draws.
enum CardElementKind: String, Codable, CaseIterable, Sendable {
  case meters
  case chart
  case runway

  var title: String {
    switch self {
    case .meters: "Limits"
    case .chart: "History Chart"
    case .runway: "Runway"
    }
  }

  var systemImage: String {
    switch self {
    case .meters: "gauge.with.dots.needle.33percent"
    case .chart: "chart.xyaxis.line"
    case .runway: "hourglass"
    }
  }
}

/// Whether bars, labels and charts count what is left or what is spent.
enum CardValueStyle: String, Codable, CaseIterable, Sendable {
  case remaining
  case used

  var title: String {
    switch self {
    case .remaining: "Remaining"
    case .used: "Used"
    }
  }

  func value(usedPercent: Double) -> Double {
    switch self {
    case .remaining: 100 - usedPercent
    case .used: usedPercent
    }
  }
}

enum HistoryRange: String, Codable, CaseIterable, Sendable {
  case sixHours
  case day
  case threeDays
  case week
  case twoWeeks

  var seconds: TimeInterval {
    switch self {
    case .sixHours: 6 * 3600
    case .day: 24 * 3600
    case .threeDays: 3 * 86400
    case .week: 7 * 86400
    case .twoWeeks: 14 * 86400
    }
  }

  var title: String {
    switch self {
    case .sixHours: "6h"
    case .day: "24h"
    case .threeDays: "3d"
    case .week: "7d"
    case .twoWeeks: "14d"
    }
  }
}

/// Which of a card's limits an element shows: a span by window length, minus
/// any hidden individually (so a newly reported limit appears by default).
struct WindowFilter: Codable, Equatable, Sendable {
  enum Span: String, Codable, CaseIterable, Sendable {
    case all
    /// Windows shorter than a day (the 5-hour session).
    case short
    /// Windows of a day or more (weekly, and scoped weeks such as Fable).
    case long

    var title: String {
      switch self {
      case .all: "All"
      case .short: "5-hour"
      case .long: "Weekly"
      }
    }
  }

  var span: Span = .all
  var hidden: Set<String> = []

  func includes(_ window: UsageWindow) -> Bool {
    guard !hidden.contains(window.id) else { return false }
    switch span {
    case .all: return true
    case .short: return window.speed == .fast
    case .long: return window.speed == .slow
    }
  }

  func inSpan(_ window: UsageWindow) -> Bool {
    WindowFilter(span: span).includes(window)
  }
}

enum ResetDisplay: String, Codable, CaseIterable, Sendable {
  case countdown
  case time
  case both
  case hidden

  var title: String {
    switch self {
    case .countdown: "Countdown"
    case .time: "Time"
    case .both: "Both"
    case .hidden: "Hidden"
    }
  }
}

enum BarThickness: String, Codable, CaseIterable, Sendable {
  case thin
  case regular
  case thick

  var title: String { rawValue.capitalized }
  var points: CGFloat {
    switch self {
    case .thin: 5
    case .regular: 8
    case .thick: 12
    }
  }
}

enum ChartCurve: String, Codable, CaseIterable, Sendable {
  case smooth
  case straight
  case steps

  var title: String { rawValue.capitalized }
}

enum ChartHeight: String, Codable, CaseIterable, Sendable {
  case compact
  case regular
  case tall

  var title: String { rawValue.capitalized }
  var points: CGFloat {
    switch self {
    case .compact: 90
    case .regular: 128
    case .tall: 180
    }
  }
}

/// One block of a card. A card holds any number, in display order; settings
/// a kind does not use are kept so switching back restores them.
struct CardElement: Codable, Equatable, Identifiable, Sendable {
  var id = UUID()
  var kind: CardElementKind
  var enabled = true
  var windows = WindowFilter()
  var valueStyle = CardValueStyle.remaining

  // Limits
  var showsPaceMarker = true
  var showsPaceStatus = true
  var reset = ResetDisplay.countdown
  var barThickness = BarThickness.regular

  // History chart
  var range = HistoryRange.day
  var curve = ChartCurve.smooth
  var height = ChartHeight.regular
  var showsPaceGuide = true
  var showsArea = true
  var showsLabels = true

  // Runway
  var showsProjectionAtReset = true
  var showsSustainablePace = false

  init(kind: CardElementKind, enabled: Bool = true, windows: WindowFilter = WindowFilter()) {
    self.kind = kind
    self.enabled = enabled
    self.windows = windows
  }

  static func chart(_ span: WindowFilter.Span, range: HistoryRange, enabled: Bool) -> CardElement {
    var element = CardElement(kind: .chart, enabled: enabled, windows: WindowFilter(span: span))
    element.range = range
    return element
  }

  /// Limits on; a 5-hour chart, a separate weekly chart and runway ready to
  /// switch on. A chart with no matching limits draws nothing.
  static var defaults: [CardElement] {
    [
      CardElement(kind: .meters),
      .chart(.short, range: .day, enabled: false),
      .chart(.long, range: .week, enabled: false),
      CardElement(kind: .runway, enabled: false),
    ]
  }

  /// A short description for lists ("5-hour · 24h").
  var summary: String {
    let limits = windows.span == .all ? "All limits" : windows.span.title
    let hidden = windows.hidden.isEmpty ? "" : " (\(windows.hidden.count) hidden)"
    switch kind {
    case .chart: return "\(limits)\(hidden) · \(range.title)"
    case .meters, .runway: return "\(limits)\(hidden)"
    }
  }

  /// Every field is optional on decode, so layouts from older and newer
  /// builds load; the pre-element kinds `history` and `forecast` map to
  /// `chart` and `runway`.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let rawKind = try c.decode(String.self, forKey: .kind)
    guard let kind = CardElementKind(rawValue: rawKind) ?? [
      "history": CardElementKind.chart, "forecast": .runway,
    ][rawKind] else {
      throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown element \(rawKind)")
    }
    self.init(kind: kind)
    func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
      (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
    id = value(.id, id)
    enabled = value(.enabled, enabled)
    windows = value(.windows, windows)
    valueStyle = value(.valueStyle, valueStyle)
    showsPaceMarker = value(.showsPaceMarker, showsPaceMarker)
    showsPaceStatus = value(.showsPaceStatus, showsPaceStatus)
    reset = value(.reset, reset)
    barThickness = value(.barThickness, barThickness)
    range = value(.range, range)
    curve = value(.curve, curve)
    height = value(.height, height)
    showsPaceGuide = value(.showsPaceGuide, showsPaceGuide)
    showsArea = value(.showsArea, showsArea)
    showsLabels = value(.showsLabels, showsLabels)
    showsProjectionAtReset = value(.showsProjectionAtReset, showsProjectionAtReset)
    showsSustainablePace = value(.showsSustainablePace, showsSustainablePace)
  }
}

/// Whether a limit may appear in the menu-bar icon.
enum MenuBarPresence: String, Codable, CaseIterable, Sendable {
  /// When it is among the most relevant.
  case auto
  /// Always, ahead of relevance.
  case pinned
  case never

  var title: String {
    switch self {
    case .auto: "By Relevance"
    case .pinned: "Always"
    case .never: "Never"
    }
  }
}

/// A card's settings for one of its limits, by `UsageWindow.id`.
struct WindowSettings: Codable, Equatable, Sendable {
  /// Replaces the limit's name on this card; nil or empty keeps it.
  var label: String?
  var menuBar = MenuBarPresence.auto

  init(label: String? = nil, menuBar: MenuBarPresence = .auto) {
    self.label = label
    self.menuBar = menuBar
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    label = try? c.decodeIfPresent(String.self, forKey: .label)
    menuBar = (try? c.decodeIfPresent(MenuBarPresence.self, forKey: .menuBar)) ?? .auto
  }
}

/// A card is a view onto one provider's quota windows. Several cards may show
/// the same provider (for example one per limit).
struct DashboardCard: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var provider: Provider
  var elements: [CardElement]
  var windowSettings: [String: WindowSettings]

  init(
    id: UUID = UUID(),
    provider: Provider,
    elements: [CardElement] = CardElement.defaults,
    windowSettings: [String: WindowSettings] = [:]
  ) {
    self.id = id
    self.provider = provider
    self.elements = elements
    self.windowSettings = windowSettings
  }

  private enum CodingKeys: String, CodingKey {
    case id, provider, elements, windowSettings
    // Before elements carried their own settings (2026-10-16).
    case hiddenWindowIDs, valueStyle, showsPaceMarker, showsCountdown, historyRange, showsPaceGuide
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let provider = try c.decode(Provider.self, forKey: .provider)
    let elements = (try? c.decodeIfPresent([LossyElement].self, forKey: .elements))?.compactMap(\.element)
    self.init(
      id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
      provider: provider,
      elements: elements ?? CardElement.defaults,
      windowSettings: (try? c.decodeIfPresent([String: WindowSettings].self, forKey: .windowSettings)) ?? [:]
    )
    if c.contains(.valueStyle) || c.contains(.historyRange) || c.contains(.hiddenWindowIDs) {
      migrateCardWideSettings(c)
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(provider, forKey: .provider)
    try c.encode(elements, forKey: .elements)
    try c.encode(windowSettings, forKey: .windowSettings)
  }

  /// The earlier layout kept one set of options per card and one history
  /// element; carry them onto each element, and split history into the
  /// 5-hour and weekly charts.
  private mutating func migrateCardWideSettings(_ c: KeyedDecodingContainer<CodingKeys>) {
    let hidden = (try? c.decodeIfPresent(Set<String>.self, forKey: .hiddenWindowIDs)) ?? []
    let style = (try? c.decodeIfPresent(CardValueStyle.self, forKey: .valueStyle)) ?? .remaining
    let marker = (try? c.decodeIfPresent(Bool.self, forKey: .showsPaceMarker)) ?? true
    let countdown = (try? c.decodeIfPresent(Bool.self, forKey: .showsCountdown)) ?? true
    let range = (try? c.decodeIfPresent(HistoryRange.self, forKey: .historyRange)) ?? .day
    let guide = (try? c.decodeIfPresent(Bool.self, forKey: .showsPaceGuide)) ?? true
    elements = elements.flatMap { element -> [CardElement] in
      var element = element
      element.windows.hidden = hidden
      element.valueStyle = style
      element.showsPaceMarker = marker
      element.showsPaceStatus = marker
      element.reset = countdown ? .countdown : .hidden
      element.showsPaceGuide = guide
      guard element.kind == .chart else { return [element] }
      var short = element
      short.windows.span = .short
      short.range = range
      var long = element
      long.id = UUID()
      long.windows.span = .long
      long.range = range.seconds > HistoryRange.week.seconds ? range : .week
      return [short, long]
    }
  }

  private struct LossyElement: Decodable {
    let element: CardElement?
    init(from decoder: Decoder) throws {
      element = try? CardElement(from: decoder)
    }
  }

  /// The card's windows from a status, ordered weekly, then short, then scoped.
  func windows(in status: UsageStatus) -> [UsageWindow] {
    (status.result(for: provider)?.windows ?? []).sorted(by: Self.displayOrder)
  }

  /// The windows `element` shows from `windows`.
  func windows(_ windows: [UsageWindow], for element: CardElement) -> [UsageWindow] {
    windows.filter(element.windows.includes)
  }

  /// The card's name for a limit: its custom label, or the limit's own.
  func label(for window: UsageWindow) -> String {
    let custom = windowSettings[window.id]?.label?.trimmingCharacters(in: .whitespacesAndNewlines)
    return custom?.isEmpty == false ? custom! : window.label
  }

  func menuBarPresence(for window: UsageWindow) -> MenuBarPresence {
    windowSettings[window.id]?.menuBar ?? .auto
  }

  static func displayOrder(_ lhs: UsageWindow, _ rhs: UsageWindow) -> Bool {
    func rank(_ window: UsageWindow) -> Int {
      if window.scope != nil { return 2 }
      return window.speed == .slow ? 0 : 1
    }
    return (rank(lhs), lhs.id) < (rank(rhs), rhs.id)
  }
}

struct DashboardLayout: Codable, Equatable, Sendable {
  static let menuBarLimits = 1...6
  static let defaultMenuBarLimit = 4

  var cards: [DashboardCard]
  /// How many windows the menu-bar icon shows, chosen by relevance.
  var menuBarLimit: Int

  init(cards: [DashboardCard], menuBarLimit: Int = DashboardLayout.defaultMenuBarLimit) {
    self.cards = cards
    self.menuBarLimit = min(Self.menuBarLimits.upperBound, max(Self.menuBarLimits.lowerBound, menuBarLimit))
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      cards: try container.decodeIfPresent([DashboardCard].self, forKey: .cards) ?? [],
      menuBarLimit: try container.decodeIfPresent(Int.self, forKey: .menuBarLimit) ?? Self.defaultMenuBarLimit
    )
  }

  static func defaultLayout(order: [Provider] = Provider.allCases) -> DashboardLayout {
    DashboardLayout(cards: order.map { DashboardCard(provider: $0) })
  }

  /// Moves `id` into `target`'s slot: after it when moving down, before it
  /// when moving up (what a drag hovering over `target` means).
  mutating func move(_ id: UUID, toPositionOf target: UUID) {
    guard id != target,
      let from = cards.firstIndex(where: { $0.id == id }),
      let to = cards.firstIndex(where: { $0.id == target })
    else { return }
    cards.insert(cards.remove(at: from), at: to)
  }

  /// Moves the card at `fromIndex` to `toIndex` (both clamped).
  mutating func move(fromIndex: Int, toIndex: Int) {
    guard cards.indices.contains(fromIndex) else { return }
    let to = min(max(0, toIndex), cards.count - 1)
    guard to != fromIndex else { return }
    cards.insert(cards.remove(at: fromIndex), at: to)
  }

  mutating func add(_ provider: Provider) {
    cards.append(DashboardCard(provider: provider))
  }

  mutating func remove(_ id: UUID) {
    cards.removeAll { $0.id == id }
  }

  subscript(id: UUID) -> DashboardCard? {
    get { cards.first { $0.id == id } }
    set {
      guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
      if let newValue { cards[index] = newValue } else { cards.remove(at: index) }
    }
  }

  /// First-appearance provider order, for surfaces that still order by
  /// provider (the menu-bar meters).
  var providerOrder: [Provider] {
    var seen = Set<Provider>()
    let ordered = cards.map(\.provider).filter { seen.insert($0).inserted }
    return ordered + Provider.allCases.filter { !seen.contains($0) }
  }
}

/// The persisted layout. Writes on every change; the menu-bar meters follow
/// the cards' provider order.
@MainActor
@Observable
final class DashboardLayoutStore {
  static let defaultsKey = "dashboardLayout"

  var layout: DashboardLayout {
    didSet {
      guard layout != oldValue else { return }
      save()
      onChange?()
    }
  }

  /// Bumped when provider colors or other appearance settings change, which
  /// live in AppSettings rather than here.
  var appearanceRevision = 0

  @ObservationIgnored var onChange: (() -> Void)?
  @ObservationIgnored private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: Self.defaultsKey),
      let saved = try? JSONDecoder().decode(DashboardLayout.self, from: data) {
      layout = saved
    } else {
      // First run after the menu was replaced: keep the user's provider order.
      layout = .defaultLayout(order: AppSettings.providerOrder)
    }
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(layout) else { return }
    defaults.set(data, forKey: Self.defaultsKey)
    AppSettings.providerOrder = layout.providerOrder
  }
}
