import AppKit

@MainActor
final class StatusItemController {
  private let statusItem = NSStatusBar.system.statusItem(withLength: 24)
  private let store = UsageStore()
  private let updater = AppUpdater()

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
    return menu
  }

  private func updateMenu() {
    let menu = statusItem.menu ?? makeMenu()
    menu.removeAllItems()

    let providers = AppSettings.providerOrder
    for (index, provider) in providers.enumerated() {
      if index > 0 {
        menu.addItem(.separator())
      }
      addProviderSection(
        provider,
        index: index,
        totalCount: providers.count,
        to: menu
      )
    }

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
    let settingsShortcut = NSMenuItem(title: "Settings…", action: #selector(openSettingsWindow), keyEquivalent: ",")
    settingsShortcut.isHidden = true
    menu.addItem(settingsShortcut)

    let refreshShortcut = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
    refreshShortcut.isHidden = true
    menu.addItem(refreshShortcut)

    let quitShortcut = NSMenuItem(title: "Quit Alight", action: #selector(quit), keyEquivalent: "q")
    quitShortcut.isHidden = true
    menu.addItem(quitShortcut)

    setTargets(in: menu)

    statusItem.menu = menu
  }

  private func addProviderSection(
    _ provider: Provider,
    index: Int,
    totalCount: Int,
    to menu: NSMenu
  ) {
    let style = AppSettings.iconStyle
    let fillMode = AppSettings.meterFillMode
    let result = store.status.result(for: provider)
    let color = GaugeIconRenderer.providerColor(provider, style: style)

    let headerItem = NSMenuItem()
    headerItem.view = ProviderHeaderRowView(
      provider: provider,
      color: color,
      result: result,
      canMoveUp: index > 0,
      canMoveDown: index < totalCount - 1,
      onColorChanged: { [weak self] _ in
        self?.applyIconSettingChange()
      },
      onMoveUp: { [weak self] in
        AppSettings.moveProvider(provider, up: true)
        self?.applyIconSettingChange()
      },
      onMoveDown: { [weak self] in
        AppSettings.moveProvider(provider, up: false)
        self?.applyIconSettingChange()
      }
    )
    menu.addItem(headerItem)

    if let result, result.ok, !result.windows.isEmpty {
      let now = Date()
      for window in result.windows {
        let windowItem = NSMenuItem()
        windowItem.view = UsageWindowRowView(
          window: window,
          accentColor: color,
          fillMode: fillMode,
          now: now
        )
        menu.addItem(windowItem)
      }
    } else {
      let reason = result?.error ?? "Usage unavailable"
      let statusItem = NSMenuItem()
      statusItem.view = ProviderStatusRowView(reason: reason)
      menu.addItem(statusItem)
    }

    if result?.needsAuth == true {
      let signIn = NSMenuItem(
        title: "Sign in to \(provider.displayName)…",
        action: #selector(signIn(_:)),
        keyEquivalent: ""
      )
      signIn.image = NSImage(
        systemSymbolName: "person.crop.circle.badge.plus",
        accessibilityDescription: "Sign In"
      )
      signIn.representedObject = provider
      menu.addItem(signIn)
    }
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

  @objc private func signIn(_ sender: NSMenuItem) {
    guard let provider = sender.representedObject as? Provider else { return }
    CLISignIn.launch(provider)
  }

  @objc private func refresh() {
    Task {
      await store.refresh(force: true)
      updateMenu()
      updateIcon()
    }
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
