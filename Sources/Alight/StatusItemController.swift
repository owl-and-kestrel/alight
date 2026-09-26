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

    let providers = Provider.allCases
    for (index, provider) in providers.enumerated() {
      if index > 0 {
        menu.addItem(.separator())
      }
      addProviderSection(provider, to: menu)
    }

    menu.addItem(.separator())
    addDisplayModeSection(to: menu)
    addSettingsSection(to: menu)

    menu.addItem(.separator())
    addReleaseSection(to: menu)

    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"))
    menu.addItem(NSMenuItem(title: "Quit Alight", action: #selector(quit), keyEquivalent: "q"))

    setTargets(in: menu)

    statusItem.menu = menu
  }

  private func addProviderSection(_ provider: Provider, to menu: NSMenu) {
    let style = AppSettings.iconStyle
    let fillMode = AppSettings.meterFillMode
    let result = store.status.result(for: provider)
    let color = GaugeIconRenderer.providerColor(provider, style: style)

    let headerItem = NSMenuItem()
    headerItem.view = ProviderHeaderRowView(provider: provider, color: color, result: result)
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

      if result.source == "cached" {
        let detailParts = [
          result.cacheAgeDisplay.map { "Last live \($0) ago" },
          result.error
        ].compactMap { $0 }
        if !detailParts.isEmpty {
          let noteItem = NSMenuItem()
          noteItem.view = ProviderNoteRowView(text: detailParts.joined(separator: " · "))
          menu.addItem(noteItem)
        }
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

  private func addDisplayModeSection(to menu: NSMenu) {
    let item = NSMenuItem(title: "Display Mode", action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    submenu.autoenablesItems = false
    let currentMode = AppSettings.displayMode

    for mode in DisplayMode.allCases {
      let child = NSMenuItem(title: mode.menuTitle, action: #selector(selectDisplayMode(_:)), keyEquivalent: "")
      child.representedObject = mode.rawValue
      if currentMode == mode {
        child.state = .on
      }
      submenu.addItem(child)
    }
    item.submenu = submenu
    menu.addItem(item)
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

  private func addReleaseSection(to menu: NSMenu) {
    let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
      ?? "development build"
    addDisabledItem("Alight \(version)", to: menu)

    let checkForUpdates = NSMenuItem(
      title: "Check for Updates…",
      action: #selector(checkForUpdatesFromMenu),
      keyEquivalent: "u"
    )
    checkForUpdates.isEnabled = updater.canCheckForUpdates
    menu.addItem(checkForUpdates)

    let automaticUpdates = NSMenuItem(
      title: "Install Updates Automatically",
      action: #selector(toggleAutomaticUpdates),
      keyEquivalent: ""
    )
    automaticUpdates.state = updater.automaticallyInstallsUpdates ? .on : .off
    menu.addItem(automaticUpdates)
  }

  private func addSettingsSection(to menu: NSMenu) {
    let settings = NSMenuItem(title: "Icon Settings", action: nil, keyEquivalent: "")
    let settingsMenu = NSMenu()
    settingsMenu.autoenablesItems = false

    addDisabledItem("Fable", to: settingsMenu)
    settingsMenu.addItem(sliderItem(for: .fableStarSize))
    settingsMenu.addItem(sliderItem(for: .fableStarRadius))

    settingsMenu.addItem(.separator())
    addDisabledItem("Short-window Hand", to: settingsMenu)
    settingsMenu.addItem(sliderItem(for: .fastHandLength))
    settingsMenu.addItem(sliderItem(for: .fastHandWidth))
    settingsMenu.addItem(sliderItem(for: .fastHandRadius))

    settingsMenu.addItem(.separator())
    addDisabledItem("Weekly Hand", to: settingsMenu)
    settingsMenu.addItem(sliderItem(for: .weeklyHandLength))
    settingsMenu.addItem(sliderItem(for: .weeklyHandWidth))
    settingsMenu.addItem(sliderItem(for: .weeklyHandRadius))

    settingsMenu.addItem(.separator())
    addDisabledItem("Scale", to: settingsMenu)
    settingsMenu.addItem(sliderItem(for: .scaleDotSize))
    settingsMenu.addItem(sliderItem(for: .scaleRadius))
    settingsMenu.addItem(sliderItem(for: .redlineWidth))

    settingsMenu.addItem(.separator())
    addDisabledItem("Center", to: settingsMenu)
    settingsMenu.addItem(sliderItem(for: .hubSize))

    settingsMenu.addItem(.separator())
    settingsMenu.addItem(colorSubmenu(
      title: "Codex Color",
      current: AppSettings.codexColor,
      action: #selector(setCodexColor(_:))
    ))
    settingsMenu.addItem(colorSubmenu(
      title: "Claude Color",
      current: AppSettings.claudeColor,
      action: #selector(setClaudeColor(_:))
    ))
    settingsMenu.addItem(colorSubmenu(
      title: "Antigravity Color",
      current: AppSettings.antigravityColor,
      action: #selector(setAntigravityColor(_:))
    ))
    settingsMenu.addItem(colorSubmenu(
      title: "Redline Color",
      current: AppSettings.redlineColor,
      action: #selector(setRedlineColor(_:))
    ))

    settingsMenu.addItem(.separator())
    addDisabledItem("Meters", to: settingsMenu)
    settingsMenu.addItem(meterLabelModeSubmenu())
    settingsMenu.addItem(meterFillModeSubmenu())
    settingsMenu.addItem(meterDirectionSubmenu())
    settingsMenu.addItem(sliderItem(for: .meterWidth))

    settingsMenu.addItem(.separator())
    settingsMenu.addItem(NSMenuItem(title: "Reset Icon Settings", action: #selector(resetIconSettings), keyEquivalent: ""))

    settings.submenu = settingsMenu
    menu.addItem(settings)
  }

  private func sliderItem(for setting: IconSliderSetting) -> NSMenuItem {
    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    item.view = SettingsSliderRow(
      setting: setting,
      value: AppSettings.value(for: setting)
    ) { [weak self] value in
      AppSettings.setValue(value, for: setting)
      self?.updateIcon()
    }
    return item
  }

  private func colorSubmenu(title: String, current: GaugeColorChoice, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    submenu.autoenablesItems = false
    for option in GaugeColorChoice.allCases {
      let child = NSMenuItem(title: option.menuTitle, action: action, keyEquivalent: "")
      child.image = swatchImage(color: option.nsColor)
      child.representedObject = option.rawValue
      if current == option {
        child.state = .on
      }
      submenu.addItem(child)
    }
    item.submenu = submenu
    return item
  }

  private func meterLabelModeSubmenu() -> NSMenuItem {
    let item = NSMenuItem(title: "Provider Swatch", action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    submenu.autoenablesItems = false
    let current = AppSettings.meterLabelMode
    for mode in MeterLabelMode.allCases {
      let child = NSMenuItem(title: mode.menuTitle, action: #selector(setMeterLabelMode(_:)), keyEquivalent: "")
      child.representedObject = mode.rawValue
      if current == mode {
        child.state = .on
      }
      submenu.addItem(child)
    }
    item.submenu = submenu
    return item
  }

  private func meterFillModeSubmenu() -> NSMenuItem {
    let item = NSMenuItem(title: "Meter Fill Style", action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    submenu.autoenablesItems = false
    let current = AppSettings.meterFillMode
    for mode in MeterFillMode.allCases {
      let child = NSMenuItem(title: mode.menuTitle, action: #selector(setMeterFillMode(_:)), keyEquivalent: "")
      child.representedObject = mode.rawValue
      if current == mode {
        child.state = .on
      }
      submenu.addItem(child)
    }
    item.submenu = submenu
    return item
  }

  private func meterDirectionSubmenu() -> NSMenuItem {
    let item = NSMenuItem(title: "Meter Direction", action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    submenu.autoenablesItems = false
    let current = AppSettings.meterDirection
    for direction in MeterDirection.allCases {
      let child = NSMenuItem(title: direction.menuTitle, action: #selector(setMeterDirection(_:)), keyEquivalent: "")
      child.representedObject = direction.rawValue
      if current == direction {
        child.state = .on
      }
      submenu.addItem(child)
    }
    item.submenu = submenu
    return item
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

  @objc private func setMeterLabelMode(_ sender: NSMenuItem) {
    guard
      let raw = sender.representedObject as? String,
      let mode = MeterLabelMode(rawValue: raw)
    else { return }
    AppSettings.meterLabelMode = mode
    applyIconSettingChange()
  }

  @objc private func setMeterFillMode(_ sender: NSMenuItem) {
    guard
      let raw = sender.representedObject as? String,
      let mode = MeterFillMode(rawValue: raw)
    else { return }
    AppSettings.meterFillMode = mode
    applyIconSettingChange()
  }

  @objc private func setMeterDirection(_ sender: NSMenuItem) {
    guard
      let raw = sender.representedObject as? String,
      let direction = MeterDirection(rawValue: raw)
    else { return }
    AppSettings.meterDirection = direction
    applyIconSettingChange()
  }

  @objc private func setCodexColor(_ sender: NSMenuItem) {
    guard
      let raw = sender.representedObject as? String,
      let color = GaugeColorChoice(rawValue: raw)
    else { return }
    AppSettings.codexColor = color
    applyIconSettingChange()
  }

  @objc private func setClaudeColor(_ sender: NSMenuItem) {
    guard
      let raw = sender.representedObject as? String,
      let color = GaugeColorChoice(rawValue: raw)
    else { return }
    AppSettings.claudeColor = color
    applyIconSettingChange()
  }

  @objc private func setAntigravityColor(_ sender: NSMenuItem) {
    guard
      let raw = sender.representedObject as? String,
      let color = GaugeColorChoice(rawValue: raw)
    else { return }
    AppSettings.antigravityColor = color
    applyIconSettingChange()
  }

  @objc private func setRedlineColor(_ sender: NSMenuItem) {
    guard
      let raw = sender.representedObject as? String,
      let color = GaugeColorChoice(rawValue: raw)
    else { return }
    AppSettings.redlineColor = color
    applyIconSettingChange()
  }

  @objc private func resetIconSettings() {
    AppSettings.resetIconStyle()
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
    updater.setAutomaticallyInstallsUpdates(!updater.automaticallyInstallsUpdates)
    updateMenu()
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }


  private func swatchImage(color: NSColor) -> NSImage {
    let image = NSImage(size: NSSize(width: 11, height: 11))
    image.lockFocus()
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 9, height: 9), xRadius: 2.5, yRadius: 2.5).fill()
    image.unlockFocus()
    image.isTemplate = false
    return image
  }

  private func addDisabledItem(_ title: String, to menu: NSMenu) {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    menu.addItem(item)
  }
}
