import SwiftUI
import UniformTypeIdentifiers

/// What the popover can ask its host to do.
struct DashboardActions {
  var refresh: () -> Void = {}
  var openSettings: () -> Void = {}
  var openHistory: () -> Void = {}
  var checkForUpdates: () -> Void = {}
  var quit: () -> Void = {}
  var signIn: (Provider) -> Void = { _ in }
  var color: (Provider) -> Color = { _ in .accentColor }
}

/// Live host: reads the shared store and layout, so the popover follows every
/// refresh without polling of its own.
struct DashboardRoot: View {
  let store: UsageStore
  @Bindable var layoutStore: DashboardLayoutStore
  let actions: DashboardActions

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      DashboardView(
        status: store.status,
        history: store.history,
        layout: $layoutStore.layout,
        now: context.date,
        actions: actions
      )
      // Re-read provider colors when appearance settings change.
      .id(layoutStore.appearanceRevision)
    }
  }
}

struct DashboardView: View {
  static let width: CGFloat = 368
  static let maximumListHeight: CGFloat = 640

  let status: UsageStatus
  let history: UsageHistory
  @Binding var layout: DashboardLayout
  let now: Date
  let actions: DashboardActions
  /// Off only for offscreen rendering, which cannot draw a scroll view.
  var scrollsCards = true

  @State private var customizing: UUID?
  @State private var dragging: UUID?
  @State private var listHeight: CGFloat = 0

  var body: some View {
    Group {
      if let id = customizing, let card = layout[id] {
        CardCustomizeView(
          card: Binding(get: { layout[id] ?? card }, set: { layout[id] = $0 }),
          availableWindows: availableWindows(for: card.provider),
          color: actions.color(card.provider),
          onDone: { withAnimation(.snappy) { customizing = nil } },
          onRemove: {
            withAnimation(.snappy) {
              customizing = nil
              layout.remove(id)
            }
          }
        )
        .transition(.move(edge: .trailing).combined(with: .opacity))
      } else {
        VStack(spacing: 0) {
          header
          Divider()
          cardList
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
      }
    }
    .frame(width: Self.width)
    .background(shortcuts)
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text("Alight").font(.headline)
        Text(updatedText).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Button(action: actions.refresh) {
        Image(systemName: "arrow.clockwise")
      }
      .help("Refresh (⌘R)")
      Menu {
        ForEach(Provider.allCases, id: \.self) { provider in
          Button(provider.displayName) {
            withAnimation(.snappy) { layout.add(provider) }
          }
        }
      } label: {
        Image(systemName: "plus")
      }
      .help("Add a card")
      Menu {
        Button("Usage History…", action: actions.openHistory)
        Button("Settings…", action: actions.openSettings)
        Button("Check for Updates…", action: actions.checkForUpdates)
        Divider()
        Picker("Menu Bar Shows", selection: $layout.menuBarLimit) {
          ForEach(DashboardLayout.menuBarLimits, id: \.self) { count in
            Text(count == 1 ? "Most Relevant Limit" : "Top \(count) Limits").tag(count)
          }
        }
        Button("Reset Cards") { withAnimation(.snappy) { layout = .defaultLayout() } }
        Divider()
        Button("Quit Alight", action: actions.quit)
      } label: {
        Image(systemName: "ellipsis.circle")
      }
    }
    .buttonStyle(.borderless)
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize(horizontal: false, vertical: true)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private var updatedText: String {
    status.results.isEmpty
      ? "Checking usage…"
      : "Updated \(status.generatedAt.formatted(.dateTime.hour().minute()))"
  }

  // MARK: Cards

  @ViewBuilder private var cardList: some View {
    if scrollsCards {
      ScrollView { cardStack }
        .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
        .frame(height: min(max(listHeight, 80), Self.maximumListHeight))
        // A drag released outside any card still ends the drag.
        .onDrop(of: [.text], isTargeted: nil) { _ in
          dragging = nil
          return true
        }
    } else {
      cardStack
    }
  }

  private var cardStack: some View {
      VStack(spacing: 10) {
        ForEach(layout.cards) { card in
          ProviderCardView(
            card: card,
            result: status.result(for: card.provider),
            history: history,
            color: actions.color(card.provider),
            now: now,
            onSignIn: { actions.signIn(card.provider) },
            onCustomize: { withAnimation(.snappy) { customizing = card.id } },
            onRemove: { withAnimation(.snappy) { layout.remove(card.id) } }
          )
          .opacity(dragging == card.id ? 0.35 : 1)
          .onDrag {
            dragging = card.id
            return NSItemProvider(object: card.id.uuidString as NSString)
          }
          .onDrop(of: [.text], delegate: CardDropDelegate(target: card.id, layout: $layout, dragging: $dragging))
        }
        if layout.cards.isEmpty {
          emptyLayout
        }
      }
      .padding(12)
      .background(GeometryReader { proxy in
        Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
      })
  }

  private var emptyLayout: some View {
    VStack(spacing: 8) {
      Image(systemName: "rectangle.stack.badge.plus").font(.title2).foregroundStyle(.secondary)
      Text("No cards. Use + to add a provider.").font(.callout).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
  }

  /// Windows the provider reports now, plus any it reported recently, so a
  /// limit that is momentarily absent can still be toggled.
  private func availableWindows(for provider: Provider) -> [UsageWindow] {
    var byID: [String: UsageWindow] = [:]
    for observation in history.observations where observation.window.provider == provider {
      byID[observation.window.id] = observation.window
    }
    for window in status.result(for: provider)?.windows ?? [] {
      byID[window.id] = window
    }
    return byID.values.sorted(by: DashboardCard.displayOrder)
  }

  /// Keyboard shortcuts while the popover is key.
  private var shortcuts: some View {
    Group {
      Button("Refresh", action: actions.refresh).keyboardShortcut("r")
      Button("Settings", action: actions.openSettings).keyboardShortcut(",")
      Button("Quit", action: actions.quit).keyboardShortcut("q")
    }
    .opacity(0)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct ListHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Live reorder: hovering a dragged card over another moves it into that slot.
private struct CardDropDelegate: DropDelegate {
  let target: UUID
  @Binding var layout: DashboardLayout
  @Binding var dragging: UUID?

  func dropEntered(info: DropInfo) {
    guard let dragging, dragging != target else { return }
    withAnimation(.snappy(duration: 0.22)) {
      layout.move(dragging, toPositionOf: target)
    }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    dragging = nil
    return true
  }
}

/// A card's settings, shown in place of the list.
struct CardCustomizeView: View {
  @Binding var card: DashboardCard
  let availableWindows: [UsageWindow]
  let color: Color
  let onDone: () -> Void
  let onRemove: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button(action: onDone) {
          Label("Cards", systemImage: "chevron.left")
        }
        .buttonStyle(.borderless)
        Spacer()
        HStack(spacing: 6) {
          Circle().fill(color).frame(width: 8, height: 8)
          Text(card.provider.displayName).font(.headline)
        }
        Spacer()
        Button("Done", action: onDone).keyboardShortcut(.defaultAction).controlSize(.small)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      Divider()

      Form {
        Section("Show, in this order") {
          ForEach(Array(card.elements.enumerated()), id: \.element.kind) { index, element in
            HStack {
              Toggle(isOn: Binding(
                get: { card.elements[index].enabled },
                set: { card.elements[index].enabled = $0 }
              )) {
                Label(element.kind.title, systemImage: element.kind.systemImage)
              }
              Spacer()
              Button { moveElement(index, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
              Button { moveElement(index, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == card.elements.count - 1)
            }
            .buttonStyle(.borderless)
          }
        }

        Section("Limits") {
          if availableWindows.isEmpty {
            Text("No limits reported yet.").foregroundStyle(.secondary)
          }
          ForEach(availableWindows) { window in
            Toggle(window.label, isOn: Binding(
              get: { !card.hiddenWindowIDs.contains(window.id) },
              set: { shown in
                if shown { card.hiddenWindowIDs.remove(window.id) } else { card.hiddenWindowIDs.insert(window.id) }
              }
            ))
          }
          Picker("Count", selection: $card.valueStyle) {
            ForEach(CardValueStyle.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .pickerStyle(.segmented)
          Toggle("Pace marker and status", isOn: $card.showsPaceMarker)
          Toggle("Reset countdown", isOn: $card.showsCountdown)
        }

        Section("History") {
          Picker("Range", selection: $card.historyRange) {
            ForEach(HistoryRange.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .pickerStyle(.segmented)
          Toggle("On-pace guide", isOn: $card.showsPaceGuide)
        }

        Section {
          Button("Remove Card", role: .destructive, action: onRemove)
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
    }
    .frame(height: 560)
  }

  private func moveElement(_ index: Int, by offset: Int) {
    let target = index + offset
    guard card.elements.indices.contains(target) else { return }
    withAnimation(.snappy) { card.elements.swapAt(index, target) }
  }
}
