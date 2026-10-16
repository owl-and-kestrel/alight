import Foundation
import Observation

/// One block of a provider card. Every card holds each kind exactly once; the
/// order is the display order and `enabled` decides whether it draws.
enum CardElement: String, Codable, CaseIterable, Sendable {
  case meters
  case history
  case forecast

  var title: String {
    switch self {
    case .meters: "Limits"
    case .history: "History"
    case .forecast: "Runway"
    }
  }

  var systemImage: String {
    switch self {
    case .meters: "gauge.with.dots.needle.33percent"
    case .history: "chart.xyaxis.line"
    case .forecast: "hourglass"
    }
  }
}

struct CardElementSetting: Codable, Equatable, Sendable {
  var kind: CardElement
  var enabled: Bool

  static let defaults: [CardElementSetting] = [
    CardElementSetting(kind: .meters, enabled: true),
    CardElementSetting(kind: .history, enabled: false),
    CardElementSetting(kind: .forecast, enabled: false),
  ]
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

  var seconds: TimeInterval {
    switch self {
    case .sixHours: 6 * 3600
    case .day: 24 * 3600
    case .threeDays: 72 * 3600
    }
  }

  var title: String {
    switch self {
    case .sixHours: "6h"
    case .day: "24h"
    case .threeDays: "3d"
    }
  }
}

/// A card is a view onto one provider's quota windows. Several cards may show
/// the same provider (for example one per limit).
struct DashboardCard: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var provider: Provider
  /// Windows left out, by `UsageWindow.id`. Exclusion rather than inclusion so
  /// a newly reported limit appears without configuration.
  var hiddenWindowIDs: Set<String>
  var elements: [CardElementSetting]
  var valueStyle: CardValueStyle
  var showsPaceMarker: Bool
  var showsCountdown: Bool
  var historyRange: HistoryRange
  var showsPaceGuide: Bool

  init(
    id: UUID = UUID(),
    provider: Provider,
    hiddenWindowIDs: Set<String> = [],
    elements: [CardElementSetting] = CardElementSetting.defaults,
    valueStyle: CardValueStyle = .remaining,
    showsPaceMarker: Bool = true,
    showsCountdown: Bool = true,
    historyRange: HistoryRange = .day,
    showsPaceGuide: Bool = true
  ) {
    self.id = id
    self.provider = provider
    self.hiddenWindowIDs = hiddenWindowIDs
    self.elements = Self.normalized(elements)
    self.valueStyle = valueStyle
    self.showsPaceMarker = showsPaceMarker
    self.showsCountdown = showsCountdown
    self.historyRange = historyRange
    self.showsPaceGuide = showsPaceGuide
  }

  /// Tolerates documents from older or newer builds: unknown element kinds are
  /// dropped, missing ones come back disabled, and missing fields default.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = DashboardCard(provider: try container.decode(Provider.self, forKey: .provider))
    let rawElements = try container.decodeIfPresent([LossyElement].self, forKey: .elements) ?? []
    self.init(
      id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? defaults.id,
      provider: defaults.provider,
      hiddenWindowIDs: try container.decodeIfPresent(Set<String>.self, forKey: .hiddenWindowIDs) ?? [],
      elements: rawElements.compactMap(\.setting),
      valueStyle: (try? container.decodeIfPresent(CardValueStyle.self, forKey: .valueStyle)) ?? defaults.valueStyle,
      showsPaceMarker: try container.decodeIfPresent(Bool.self, forKey: .showsPaceMarker) ?? defaults.showsPaceMarker,
      showsCountdown: try container.decodeIfPresent(Bool.self, forKey: .showsCountdown) ?? defaults.showsCountdown,
      historyRange: (try? container.decodeIfPresent(HistoryRange.self, forKey: .historyRange)) ?? defaults.historyRange,
      showsPaceGuide: try container.decodeIfPresent(Bool.self, forKey: .showsPaceGuide) ?? defaults.showsPaceGuide
    )
  }

  func isEnabled(_ kind: CardElement) -> Bool {
    elements.first { $0.kind == kind }?.enabled ?? false
  }

  mutating func setEnabled(_ kind: CardElement, _ enabled: Bool) {
    guard let index = elements.firstIndex(where: { $0.kind == kind }) else { return }
    elements[index].enabled = enabled
  }

  /// Enabled elements in display order.
  var visibleElements: [CardElement] {
    elements.filter(\.enabled).map(\.kind)
  }

  /// The card's windows from a status, ordered weekly, then short, then scoped.
  func windows(in status: UsageStatus) -> [UsageWindow] {
    (status.result(for: provider)?.windows ?? [])
      .filter { !hiddenWindowIDs.contains($0.id) }
      .sorted(by: Self.displayOrder)
  }

  static func displayOrder(_ lhs: UsageWindow, _ rhs: UsageWindow) -> Bool {
    func rank(_ window: UsageWindow) -> Int {
      if window.scope != nil { return 2 }
      return window.speed == .slow ? 0 : 1
    }
    return (rank(lhs), lhs.id) < (rank(rhs), rhs.id)
  }

  private static func normalized(_ elements: [CardElementSetting]) -> [CardElementSetting] {
    var seen = Set<CardElement>()
    var result = elements.filter { seen.insert($0.kind).inserted }
    for kind in CardElement.allCases where !seen.contains(kind) {
      result.append(CardElementSetting(kind: kind, enabled: false))
    }
    return result
  }

  private struct LossyElement: Decodable {
    let setting: CardElementSetting?
    init(from decoder: Decoder) throws {
      setting = try? CardElementSetting(from: decoder)
    }
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
