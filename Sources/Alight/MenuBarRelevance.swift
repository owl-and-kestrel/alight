import Foundation
import OSLog

/// Chooses what the menu-bar icon shows: the `limit` most relevant windows
/// across the dashboard's cards. Alight scores relevance; Vane does the
/// selection (rank, then the caller's item cap), so selection semantics stay
/// in one place upstream.
enum MenuBarRelevance {
  private static let logger = Logger(subsystem: "com.owlandkestrel.alight", category: "menubar")

  /// 0...1. Running over pace matters most; little allowance left matters
  /// next; a reading the app could not refresh counts for less.
  static func salience(_ window: UsageWindow, result: ProviderResult?) -> Double {
    let overPace = min(1, max(0, -window.pressurePercent / 30))
    let scarcity = min(1, max(0, (60 - window.remainingPercent) / 60))
    var score = 0.6 * overPace + 0.4 * scarcity
    if result?.source == "cached" { score *= 0.7 }
    return min(1, max(0, score))
  }

  /// The windows the menu bar can draw, in card order, without duplicates,
  /// each with its presence from the first card that shows it. Limits a card
  /// sets to Never are left out.
  static func candidates(status: UsageStatus, layout: DashboardLayout) -> [(window: UsageWindow, presence: MenuBarPresence)] {
    var seen = Set<String>()
    return layout.cards
      .flatMap { card in card.windows(in: status).map { (window: $0, presence: card.menuBarPresence(for: $0)) } }
      .filter { $0.window.visualStyle != .menuRow && seen.insert($0.window.id).inserted }
      .filter { $0.presence != .never }
  }

  /// Pinned limits go first and stay ahead of relevance (Vane's `pinned`).
  static func tree(status: UsageStatus, layout: DashboardLayout) -> LodNode {
    LodNode(id: "menubar", title: "Menu bar", children: candidates(status: status, layout: layout).map { candidate in
      LodNode(
        id: candidate.window.id,
        title: candidate.window.qualifiedLabel,
        salience: salience(candidate.window, result: status.result(for: candidate.window.provider)),
        pinned: candidate.presence == .pinned ? true : nil
      )
    })
  }

  /// `status` reduced to the selected windows, for the existing renderers.
  @MainActor
  static func select(
    status: UsageStatus,
    layout: DashboardLayout,
    core: Result<CoreScript, Error> = CoreScript.shared
  ) -> UsageStatus {
    let limit = max(1, layout.menuBarLimit)
    let tree = tree(status: status, layout: layout)
    var selected: Set<String>
    do {
      let result = try core.get().fit(
        tree,
        options: VaneFitOptions(budget: VaneBudget(bytes: 16_384), format: .json, order: .rank),
        accept: { value, _ in (value?.children?.count ?? 0) <= limit }
      )
      selected = Set(result.value?.children?.compactMap(\.id) ?? [])
    } catch {
      // A broken bundle must not blank the menu bar: show every candidate.
      logger.error("Menu-bar selection unavailable: \(String(describing: error), privacy: .public)")
      selected = Set(tree.children?.compactMap(\.id) ?? [])
    }
    var reduced = status
    reduced.results = status.results.map { result in
      result.replacingWindows(result.windows.filter { selected.contains($0.id) })
    }
    return reduced
  }
}
