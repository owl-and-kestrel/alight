import AppKit

@MainActor
final class StatusItemController {
  private let statusItem = NSStatusBar.system.statusItem(withLength: 24)
  private let store = UsageStore()
  private let updater = AppUpdater()
  private lazy var usageInsightsWindow = UsageInsightsWindowController(store: store)
  /// The dropdown's provider list view; kept so a reorder can animate it
  /// instead of rebuilding the menu.
  private var sectionsContainer: ProviderSectionsView?

  init() {
    if let button = statusItem.button {
      button.bezelStyle = .regularSquare
      button.isBordered = false
      button.imagePosition = .imageOnly
      button.imageScaling = .scaleProportionallyDown
      button.toolTip = "Alight"
    }
    statusItem.menu = makeMenu()

    // Connect SettingsWindowController
    SettingsWindowController.shared.onSettingChanged = { [weak self] in
      self?.applyIconSettingChange()
    }
    SettingsWindowController.shared.onCheckForUpdates = { [weak self] in
      self?.updater.checkForUpdates()
    }
    SettingsWindowController.shared.onAutomaticUpdatesChanged = { [weak self] enabled in
      self?.updater.setAutomaticallyInstallsUpdates(enabled)
    }
    SettingsWindowController.shared.automaticallyInstallsUpdates = updater.automaticallyInstallsUpdates

    updateIcon()

    Task {
      await store.refresh()
      updateMenu()
      updateIcon()
      startRefreshLoop()
    }
  }

  private func startRefreshLoop() {
    Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        await store.refresh()
        updateMenu()
        updateIcon()
      }
    }
  }

  private func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(Self.usageHistoryMenuItem(target: self))
    return menu
  }

  private func updateMenu() {
    let menu = statusItem.menu ?? makeMenu()
    menu.removeAllItems()

    let providers = AppSettings.providerOrder

    // Every provider section lives inside one container view so a reorder can
    // animate instead of asking NSMenu to re-lay-out individual items.
    let sections = ProviderSectionsView(
      frame: NSRect(x: 0, y: 0, width: ProviderSectionsView.width, height: 0)
    )
    sections.setSections(providers.map { provider in
      makeProviderSection(provider)
    })
    sectionsContainer = sections

    let sectionsItem = NSMenuItem()
    sectionsItem.view = sections
    menu.addItem(sectionsItem)

    menu.addItem(.separator())

    menu.addItem(Self.usageHistoryMenuItem(target: self))
    menu.addItem(.separator())

    // Footer row with Refresh button, Status text, and Gear button
    let statusText: String
    if store.status.ok {
      let relative = store.status.generatedAt.formatted(.dateTime.hour().minute())
      statusText = "Alight · Updated \(relative)"
    } else {
      statusText = "Alight · Usage unavailable"
    }

    let footerItem = NSMenuItem()
    footerItem.view = MenuFooterRowView(
      statusText: statusText,
      onRefresh: { [weak self] in
        self?.refresh()
      },
      onGearClick: { [weak self] in
        self?.openSettingsWindow()
      }
    )
    menu.addItem(footerItem)

    // Hidden items for standard keyboard shortcuts
    let settingsShortcut = Self.keyboardShortcut(title: "Settings…", action: #selector(openSettingsWindow), key: ",")
    menu.addItem(settingsShortcut)

    let refreshShortcut = Self.keyboardShortcut(title: "Refresh", action: #selector(refresh), key: "r")
    menu.addItem(refreshShortcut)

    let quitShortcut = Self.keyboardShortcut(title: "Quit Alight", action: #selector(quit), key: "q")
    menu.addItem(quitShortcut)

    setTargets(in: menu)

    statusItem.menu = menu
  }

  static func keyboardShortcut(title: String, action: Selector, key: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.isHidden = true
    item.allowsKeyEquivalentWhenHidden = true
    return item
  }

  static func usageHistoryMenuItem(target: AnyObject) -> NSMenuItem {
    let item = NSMenuItem(title: "Usage History…", action: #selector(openUsageHistory), keyEquivalent: "")
    item.target = target
    return item
  }

  private func makeProviderSection(_ provider: Provider) -> ProviderSectionView {
    let style = AppSettings.iconStyle
    let fillMode = AppSettings.meterFillMode
    let result = store.status.result(for: provider)
    let color = GaugeIconRenderer.providerColor(provider, style: style)

    return ProviderSectionView(
      provider: provider,
      color: color,
      result: result,
      fillMode: fillMode,
      onColorChanged: { [weak self] _ in
        self?.applyIconSettingChange()
      },
      onMoveUp: { [weak self] in
        AppSettings.moveProvider(provider, up: true)
        self?.providerOrderChanged(moving: provider)
      },
      onMoveDown: { [weak self] in
        AppSettings.moveProvider(provider, up: false)
        self?.providerOrderChanged(moving: provider)
      },
      onSignIn: { [weak self] in
        self?.signIn(provider)
      }
    )
  }

  /// Applies a reorder to the open dropdown with a slide animation, then
  /// refreshes the chevrons and the menu-bar icon (whose cards follow the
  /// same order).
  private func providerOrderChanged(moving provider: Provider) {
    let order = AppSettings.providerOrder
    sectionsContainer?.applyOrder(order, moving: provider, animated: true)
    sectionsContainer?.updateMoveLimits()
    updateIcon()
  }

  @objc private func openSettingsWindow() {
    statusItem.menu?.cancelTracking()
    SettingsWindowController.shared.show()
  }

  private func updateIcon() {
    let mode = AppSettings.displayMode
    let image: NSImage
    switch mode {
    case .gauge:
      statusItem.length = 24
      image = GaugeIconRenderer.image(status: store.status, style: AppSettings.iconStyle)
    case .meters:
      let style = AppSettings.meterStyle
      statusItem.length = MeterIconRenderer.size(for: style).width + 6
      image = MeterIconRenderer.image(status: store.status, style: style)
    }
    statusItem.button?.image = image
    statusItem.button?.toolTip = store.status.summary
  }

  private func setTargets(in menu: NSMenu) {
    for item in menu.items {
      if item.action != nil {
        item.target = self
      }
      if let submenu = item.submenu {
        setTargets(in: submenu)
      }
    }
  }

  private func applyIconSettingChange() {
    updateMenu()
    updateIcon()
  }

  @objc private func selectDisplayMode(_ sender: NSMenuItem) {
    guard
      let raw = sender.representedObject as? String,
      let mode = DisplayMode(rawValue: raw)
    else { return }
    AppSettings.displayMode = mode
    applyIconSettingChange()
  }

  private func signIn(_ provider: Provider) {
    CLISignIn.launch(provider)
  }

  @objc private func refresh() {
    Task {
      await store.refresh(force: true)
      updateMenu()
      updateIcon()
    }
  }

  @objc private func openUsageHistory() {
    usageInsightsWindow.showInsights()
  }

  @objc private func checkForUpdatesFromMenu() {
    updater.checkForUpdates()
  }

  @objc private func toggleAutomaticUpdates() {
    let newValue = !updater.automaticallyInstallsUpdates
    updater.setAutomaticallyInstallsUpdates(newValue)
    SettingsWindowController.shared.automaticallyInstallsUpdates = newValue
    updateMenu()
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }
}
