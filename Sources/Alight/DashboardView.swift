import SwiftUI

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
  @State private var listHeight: CGFloat = 0
  /// The card being dragged, how far it has moved, and every card's height,
  /// for the live reorder.
  @State private var dragging: UUID?
  @State private var dragTranslation: CGFloat = 0
  @State private var cardHeights: [UUID: CGFloat] = [:]

  var body: some View {
    Group {
      if let id = customizing, let card = layout[id] {
        CardCustomizeView(
          card: Binding(get: { layout[id] ?? card }, set: { layout[id] = $0 }),
          availableWindows: availableWindows(for: card.provider),
          color: actions.color(card.provider),
          result: status.result(for: card.provider),
          history: history,
          now: now,
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
      ScrollView {
        cardStack.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
      }
      .frame(height: min(max(listHeight, 80), Self.maximumListHeight))
    } else {
      cardStack
    }
  }

  private var cardStack: some View {
    let heights = layout.cards.map { cardHeights[$0.id] ?? 0 }
    let from = dragging.flatMap { id in layout.cards.firstIndex { $0.id == id } }
    let target = from.map {
      CardReorder.targetIndex(heights: heights, spacing: CardReorder.spacing, from: $0, translation: dragTranslation)
    }
    return VStack(spacing: CardReorder.spacing) {
      ForEach(Array(layout.cards.enumerated()), id: \.element.id) { index, card in
        let isDragged = card.id == dragging
        let shift = from.flatMap { from in
          target.map { CardReorder.shift(index: index, heights: heights, spacing: CardReorder.spacing, from: from, target: $0) }
        } ?? 0
        ProviderCardView(
          card: card,
          result: status.result(for: card.provider),
          history: history,
          color: actions.color(card.provider),
          now: now,
          onSignIn: { actions.signIn(card.provider) },
          onCustomize: { withAnimation(.snappy) { customizing = card.id } },
          onRemove: { withAnimation(.snappy) { layout.remove(card.id) } },
          onMove: { offset in
            withAnimation(.snappy) { layout.move(fromIndex: index, toIndex: index + offset) }
          },
          canMove: (up: index > 0, down: index < layout.cards.count - 1),
          onReorderChanged: { translation in
            dragging = card.id
            dragTranslation = translation
          },
          onReorderEnded: { endReorder() }
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeights[card.id] = $0 }
        // The dragged card follows the pointer exactly; the others spring
        // aside as it passes their middles.
        .offset(y: isDragged ? dragTranslation : shift)
        .animation(isDragged ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: shift)
        .scaleEffect(isDragged ? 1.02 : 1)
        .shadow(color: .black.opacity(isDragged ? 0.22 : 0), radius: isDragged ? 14 : 0, y: isDragged ? 8 : 0)
        .animation(.easeOut(duration: 0.14), value: isDragged)
        .zIndex(isDragged ? 1 : 0)
      }
      if layout.cards.isEmpty {
        emptyLayout
      }
    }
    .padding(12)
  }

  /// Drops the dragged card into its slot. The order change and the offset
  /// reset animate together, so the card glides from where it was released
  /// and the others stay where they already slid to.
  private func endReorder() {
    guard let dragging, let from = layout.cards.firstIndex(where: { $0.id == dragging }) else {
      self.dragging = nil
      dragTranslation = 0
      return
    }
    let heights = layout.cards.map { cardHeights[$0.id] ?? 0 }
    let target = CardReorder.targetIndex(heights: heights, spacing: CardReorder.spacing, from: from, translation: dragTranslation)
    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
      layout.move(fromIndex: from, toIndex: target)
      self.dragging = nil
      dragTranslation = 0
    }
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

/// Reorder geometry for a vertical stack of cards: where a dragged card
/// lands and how far the others step aside. Pure, for testing.
enum CardReorder {
  static let spacing: CGFloat = 10

  /// Moving down, the card takes a slot once its bottom edge passes that
  /// card's middle; moving up, once its top edge does.
  static func targetIndex(heights: [CGFloat], spacing: CGFloat, from: Int, translation: CGFloat) -> Int {
    guard heights.indices.contains(from) else { return from }
    var tops: [CGFloat] = []
    var y: CGFloat = 0
    for height in heights {
      tops.append(y)
      y += height + spacing
    }
    let top = tops[from] + translation
    let bottom = top + heights[from]
    var target = from
    if translation > 0 {
      for index in heights.indices where index > from && bottom > tops[index] + heights[index] / 2 {
        target = index
      }
    } else if translation < 0 {
      for index in heights.indices.reversed() where index < from && top < tops[index] + heights[index] / 2 {
        target = index
      }
    }
    return target
  }

  /// How far a card that is not being dragged moves to open `target`.
  static func shift(index: Int, heights: [CGFloat], spacing: CGFloat, from: Int, target: Int) -> CGFloat {
    guard heights.indices.contains(from), index != from else { return 0 }
    let gap = heights[from] + spacing
    if from < target, index > from, index <= target { return -gap }
    if from > target, index >= target, index < from { return gap }
    return 0
  }
}

/// A card's settings, shown in place of the list, under a live preview of
/// the card so every change shows as it is made. The card page lists its
/// elements and limits; an element page holds that element's settings.
struct CardCustomizeView: View {
  static let settingsHeight: CGFloat = 330

  @Binding var card: DashboardCard
  let availableWindows: [UsageWindow]
  let color: Color
  let result: ProviderResult?
  let history: UsageHistory
  let now: Date
  let onDone: () -> Void
  let onRemove: () -> Void

  static let maximumPreviewHeight: CGFloat = 340

  @State private var editing: UUID?
  @State private var previewHeight: CGFloat = 0

  init(
    card: Binding<DashboardCard>, availableWindows: [UsageWindow], color: Color, result: ProviderResult?,
    history: UsageHistory, now: Date, editing: UUID? = nil, onDone: @escaping () -> Void, onRemove: @escaping () -> Void
  ) {
    _card = card
    self.availableWindows = availableWindows
    self.color = color
    self.result = result
    self.history = history
    self.now = now
    self.onDone = onDone
    self.onRemove = onRemove
    _editing = State(initialValue: editing)
  }

  var body: some View {
    VStack(spacing: 0) {
      titleBar
      Divider()
      preview
      Divider()

      Group {
        if let editing, let index = card.elements.firstIndex(where: { $0.id == editing }) {
          ElementSettingsForm(
            element: $card.elements[index],
            windows: availableWindows,
            label: card.label(for:),
            onDelete: {
              withAnimation(.snappy) {
                self.editing = nil
                card.elements.remove(at: index)
              }
            }
          )
          .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
          cardForm.transition(.move(edge: .leading).combined(with: .opacity))
        }
      }
      .frame(height: Self.settingsHeight)
      .clipped()
    }
  }

  /// The card as it will look, scrolled to the element being edited when the
  /// card is taller than the space for it.
  private var preview: some View {
    ScrollViewReader { proxy in
      ScrollView {
        ProviderCardView(card: card, result: result, history: history, color: color, now: now, highlightedElement: editing)
          .allowsHitTesting(false)
          .animation(.snappy, value: card)
          .animation(.snappy, value: editing)
          .padding(12)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewHeight = $0 }
          .accessibilityLabel("Preview of the \(card.provider.displayName) card")
      }
      .frame(height: min(max(previewHeight, 60), Self.maximumPreviewHeight))
      .onChange(of: editing, initial: true) { _, element in
        guard let element else { return }
        withAnimation(.snappy) { proxy.scrollTo(element, anchor: .center) }
      }
    }
  }

  private var titleBar: some View {
    HStack {
      Button {
        withAnimation(.snappy) {
          if editing != nil { editing = nil } else { onDone() }
        }
      } label: {
        Label(editing == nil ? "Cards" : card.provider.displayName, systemImage: "chevron.left")
      }
      .buttonStyle(.borderless)
      Spacer()
      HStack(spacing: 6) {
        Circle().fill(color).frame(width: 8, height: 8)
        Text(editing.flatMap { id in card.elements.first { $0.id == id }?.kind.title } ?? card.provider.displayName)
          .font(.headline)
      }
      Spacer()
      Button("Done", action: onDone).keyboardShortcut(.defaultAction).controlSize(.small)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  // MARK: Card page

  private var cardForm: some View {
    Form {
      Section {
        ForEach(Array(card.elements.enumerated()), id: \.element.id) { index, element in
          HStack(spacing: 8) {
            Toggle("", isOn: $card.elements[index].enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            Button {
              withAnimation(.snappy) { editing = element.id }
            } label: {
              HStack {
                Label {
                  VStack(alignment: .leading, spacing: 1) {
                    Text(element.kind.title)
                    Text(element.summary).font(.caption).foregroundStyle(.secondary)
                  }
                } icon: {
                  Image(systemName: element.kind.systemImage)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { moveElement(index, by: -1) } label: { Image(systemName: "chevron.up") }
              .disabled(index == 0)
            Button { moveElement(index, by: 1) } label: { Image(systemName: "chevron.down") }
              .disabled(index == card.elements.count - 1)
          }
          .buttonStyle(.borderless)
        }
        Menu {
          ForEach(CardElementKind.allCases, id: \.self) { kind in
            Button {
              let element = CardElement(kind: kind)
              withAnimation(.snappy) {
                card.elements.append(element)
                editing = element.id
              }
            } label: {
              Label(kind.title, systemImage: kind.systemImage)
            }
          }
        } label: {
          Label("Add Element", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      } header: {
        Text("Elements")
      } footer: {
        Text("Switch elements on and off, open one for its settings, or add another (for example a second chart for other limits).")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("Limits") {
        if availableWindows.isEmpty {
          Text("No limits reported yet.").foregroundStyle(.secondary)
        }
        ForEach(availableWindows) { window in
          LimitSettingsRow(window: window, settings: windowSettings(window.id))
        }
      }

      Section {
        Button("Remove Card", role: .destructive, action: onRemove)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

  private func windowSettings(_ id: String) -> Binding<WindowSettings> {
    Binding(
      get: { card.windowSettings[id] ?? WindowSettings() },
      set: { card.windowSettings[id] = $0 == WindowSettings() ? nil : $0 }
    )
  }

  private func moveElement(_ index: Int, by offset: Int) {
    let target = index + offset
    guard card.elements.indices.contains(target) else { return }
    withAnimation(.snappy) { card.elements.swapAt(index, target) }
  }
}

/// A limit's name on this card and its place in the menu bar.
private struct LimitSettingsRow: View {
  let window: UsageWindow
  @Binding var settings: WindowSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField(window.label, text: Binding(
        get: { settings.label ?? "" },
        set: { settings.label = $0.isEmpty ? nil : $0 }
      ), prompt: Text(window.label))
      .textFieldStyle(.roundedBorder)
      Picker("Menu bar", selection: $settings.menuBar) {
        ForEach(MenuBarPresence.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.menu)
      .disabled(window.visualStyle == .menuRow)
      .help(window.visualStyle == .menuRow ? "This limit has no menu-bar mark." : "When this limit appears in the menu-bar icon")
    }
    .padding(.vertical, 2)
  }
}

/// One element's settings.
private struct ElementSettingsForm: View {
  @Binding var element: CardElement
  let windows: [UsageWindow]
  let label: (UsageWindow) -> String
  let onDelete: () -> Void

  var body: some View {
    Form {
      Section {
        Toggle("Show on card", isOn: $element.enabled)
        Picker("Kind", selection: $element.kind) {
          ForEach(CardElementKind.allCases, id: \.self) { Label($0.title, systemImage: $0.systemImage).tag($0) }
        }
      }

      Section("Limits") {
        Picker("Show", selection: $element.windows.span) {
          ForEach(WindowFilter.Span.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        ForEach(windows.filter(element.windows.inSpan)) { window in
          Toggle(label(window), isOn: Binding(
            get: { !element.windows.hidden.contains(window.id) },
            set: { shown in
              if shown { element.windows.hidden.remove(window.id) } else { element.windows.hidden.insert(window.id) }
            }
          ))
        }
      }

      switch element.kind {
      case .meters: metersSettings
      case .chart: chartSettings
      case .runway: runwaySettings
      }

      Section {
        Button("Delete Element", role: .destructive, action: onDelete)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

  private var countPicker: some View {
    Picker("Count", selection: $element.valueStyle) {
      ForEach(CardValueStyle.allCases, id: \.self) { Text($0.title).tag($0) }
    }
    .pickerStyle(.segmented)
  }

  private var metersSettings: some View {
    Section("Display") {
      countPicker
      Picker("Bar", selection: $element.barThickness) {
        ForEach(BarThickness.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      Toggle("Pace marker on bar", isOn: $element.showsPaceMarker)
      Toggle("Pace status", isOn: $element.showsPaceStatus)
      Picker("Reset", selection: $element.reset) {
        ForEach(ResetDisplay.allCases, id: \.self) { Text($0.title).tag($0) }
      }
    }
  }

  private var chartSettings: some View {
    Section("Display") {
      Picker("Range", selection: $element.range) {
        ForEach(HistoryRange.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      countPicker
      Picker("Line", selection: $element.curve) {
        ForEach(ChartCurve.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      Picker("Height", selection: $element.height) {
        ForEach(ChartHeight.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      Toggle("On-pace guide", isOn: $element.showsPaceGuide)
      Toggle("Area fill", isOn: $element.showsArea)
      Toggle("Legend and labels", isOn: $element.showsLabels)
    }
  }

  private var runwaySettings: some View {
    Section("Display") {
      Toggle("Projection at reset", isOn: $element.showsProjectionAtReset)
      Toggle("Sustainable pace", isOn: $element.showsSustainablePace)
    }
  }
}
