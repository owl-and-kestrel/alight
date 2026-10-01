import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
  static let shared = SettingsWindowController()

  var onSettingChanged: (@MainActor () -> Void)?
  var onCheckForUpdates: (@MainActor () -> Void)?
  var onAutomaticUpdatesChanged: (@MainActor (Bool) -> Void)?
  var automaticallyInstallsUpdates: Bool = false {
    didSet {
      autoUpdateCheckbox?.state = automaticallyInstallsUpdates ? .on : .off
    }
  }

  private var tabView: NSTabView!
  private var autoUpdateCheckbox: NSButton?

  convenience init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 490),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Alight Settings"
    window.center()
    window.isReleasedWhenClosed = false

    self.init(window: window)
    setupToolbar(for: window)
    setupTabs(for: window)
  }

  func show() {
    guard let window else { return }
    reloadControls()
    window.center()
    showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  // MARK: - Toolbar & Tabs

  private static let generalTabId = "general"
  private static let gaugeTabId = "gauge"
  private static let metersTabId = "meters"
  private static let updatesTabId = "updates"

  private func setupToolbar(for window: NSWindow) {
    let toolbar = NSToolbar(identifier: "AlightSettingsToolbar")
    toolbar.allowsUserCustomization = false
    toolbar.autosavesConfiguration = false
    toolbar.displayMode = .iconAndLabel
    toolbar.delegate = self
    toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(Self.generalTabId)
    window.toolbar = toolbar
    window.toolbarStyle = .preference
  }

  private func setupTabs(for window: NSWindow) {
    tabView = NSTabView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 440, height: 490))
    tabView.tabViewType = .noTabsNoBorder
    tabView.autoresizingMask = [.width, .height]

    let generalItem = NSTabViewItem(identifier: Self.generalTabId)
    generalItem.view = makeGeneralView()
    tabView.addTabViewItem(generalItem)

    let gaugeItem = NSTabViewItem(identifier: Self.gaugeTabId)
    gaugeItem.view = makeGaugeView()
    tabView.addTabViewItem(gaugeItem)

    let metersItem = NSTabViewItem(identifier: Self.metersTabId)
    metersItem.view = makeMetersView()
    tabView.addTabViewItem(metersItem)

    let updatesItem = NSTabViewItem(identifier: Self.updatesTabId)
    updatesItem.view = makeUpdatesView()
    tabView.addTabViewItem(updatesItem)

    window.contentView = tabView
  }

  // MARK: - NSToolbarDelegate

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [
      NSToolbarItem.Identifier(Self.generalTabId),
      NSToolbarItem.Identifier(Self.gaugeTabId),
      NSToolbarItem.Identifier(Self.metersTabId),
      NSToolbarItem.Identifier(Self.updatesTabId)
    ]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    let item = NSToolbarItem(itemIdentifier: itemIdentifier)
    item.target = self
    item.action = #selector(toolbarItemClicked(_:))

    switch itemIdentifier.rawValue {
    case Self.generalTabId:
      item.label = "General"
      item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
    case Self.gaugeTabId:
      item.label = "Gauge Dial"
      item.image = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "Gauge Dial")
        ?? NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "Gauge Dial")
    case Self.metersTabId:
      item.label = "Meters"
      item.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Meters")
        ?? NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: "Meters")
    case Self.updatesTabId:
      item.label = "Updates"
      item.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Updates")
    default:
      return nil
    }

    return item
  }

  @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
    let id = sender.itemIdentifier.rawValue
    tabView.selectTabViewItem(withIdentifier: id)
  }

  // MARK: - Tab Views

  private func makeGeneralView() -> NSView {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 440))

    // Display Mode Header
    let modeTitle = NSTextField(labelWithString: "Menu Bar Display Mode")
    modeTitle.font = .systemFont(ofSize: 13, weight: .bold)
    modeTitle.frame = NSRect(x: 30, y: 395, width: 380, height: 18)
    container.addSubview(modeTitle)

    let modeSubtitle = NSTextField(wrappingLabelWithString: "Choose whether Alight displays the circular pace gauge or horizontal provider meter cards in the macOS menu bar.")
    modeSubtitle.font = .systemFont(ofSize: 11, weight: .regular)
    modeSubtitle.textColor = .secondaryLabelColor
    modeSubtitle.frame = NSRect(x: 30, y: 355, width: 380, height: 32)
    container.addSubview(modeSubtitle)

    let modeSeg = NSSegmentedControl(labels: ["Gauge Dial", "Provider Meters"], trackingMode: .selectOne, target: self, action: #selector(displayModeChanged(_:)))
    modeSeg.selectedSegment = AppSettings.displayMode == .gauge ? 0 : 1
    modeSeg.frame = NSRect(x: 30, y: 325, width: 380, height: 24)
    container.addSubview(modeSeg)

    // Divider
    let sep1 = NSBox(frame: NSRect(x: 30, y: 305, width: 380, height: 1))
    sep1.boxType = .separator
    container.addSubview(sep1)

    // Provider Colors Header
    let colorsTitle = NSTextField(labelWithString: "Provider Colors")
    colorsTitle.font = .systemFont(ofSize: 13, weight: .bold)
    colorsTitle.frame = NSRect(x: 30, y: 275, width: 380, height: 18)
    container.addSubview(colorsTitle)

    let colorsSubtitle = NSTextField(labelWithString: "Select accent colors used on the menu bar icon and info cards.")
    colorsSubtitle.font = .systemFont(ofSize: 11, weight: .regular)
    colorsSubtitle.textColor = .secondaryLabelColor
    colorsSubtitle.frame = NSRect(x: 30, y: 255, width: 380, height: 16)
    container.addSubview(colorsSubtitle)

    var yPos: CGFloat = 220
    for provider in Provider.allCases {
      let label = NSTextField(labelWithString: "\(provider.displayName):")
      label.font = .systemFont(ofSize: 12, weight: .medium)
      label.frame = NSRect(x: 30, y: yPos, width: 100, height: 18)
      container.addSubview(label)

      let popUp = makeColorPopUp(for: provider, frame: NSRect(x: 135, y: yPos - 2, width: 150, height: 24))
      container.addSubview(popUp)

      yPos -= 32
    }

    // Redline Color
    let redlineLabel = NSTextField(labelWithString: "Redline Arc:")
    redlineLabel.font = .systemFont(ofSize: 12, weight: .medium)
    redlineLabel.frame = NSRect(x: 30, y: yPos, width: 100, height: 18)
    container.addSubview(redlineLabel)

    let redlinePopUp = NSPopUpButton(frame: NSRect(x: 135, y: yPos - 2, width: 150, height: 24), pullsDown: false)
    for choice in GaugeColorChoice.allCases {
      let item = NSMenuItem(title: choice.menuTitle, action: #selector(redlineColorChanged(_:)), keyEquivalent: "")
      item.image = ColorSwatchButton.swatchImage(color: choice.nsColor)
      item.representedObject = choice
      item.target = self
      redlinePopUp.menu?.addItem(item)
    }
    redlinePopUp.selectItem(withTitle: AppSettings.redlineColor.menuTitle)
    container.addSubview(redlinePopUp)

    // Divider
    yPos -= 25
    let sep2 = NSBox(frame: NSRect(x: 30, y: yPos, width: 380, height: 1))
    sep2.boxType = .separator
    container.addSubview(sep2)

    // Reset button & Quit button
    yPos -= 35
    let resetBtn = NSButton(title: "Reset Settings", target: self, action: #selector(resetSettingsClicked))
    resetBtn.frame = NSRect(x: 30, y: yPos, width: 140, height: 28)
    resetBtn.bezelStyle = .rounded
    container.addSubview(resetBtn)

    let quitBtn = NSButton(title: "Quit Alight", target: self, action: #selector(quitClicked))
    quitBtn.frame = NSRect(x: 180, y: yPos, width: 110, height: 28)
    quitBtn.bezelStyle = .rounded
    container.addSubview(quitBtn)

    return container
  }

  @objc private func quitClicked() {
    NSApplication.shared.terminate(nil)
  }

  private func makeColorPopUp(for provider: Provider, frame: NSRect) -> NSPopUpButton {
    let popUp = NSPopUpButton(frame: frame, pullsDown: false)
    let current = AppSettings.colorChoice(for: provider)
    for choice in GaugeColorChoice.allCases {
      let item = NSMenuItem(title: choice.menuTitle, action: #selector(providerColorChanged(_:)), keyEquivalent: "")
      item.image = ColorSwatchButton.swatchImage(color: choice.nsColor)
      item.representedObject = (provider, choice)
      item.target = self
      popUp.menu?.addItem(item)
    }
    popUp.selectItem(withTitle: current.menuTitle)
    return popUp
  }

  @objc private func displayModeChanged(_ sender: NSSegmentedControl) {
    AppSettings.displayMode = sender.selectedSegment == 0 ? .gauge : .meters
    onSettingChanged?()
  }

  @objc private func providerColorChanged(_ sender: NSMenuItem) {
    guard let (provider, choice) = sender.representedObject as? (Provider, GaugeColorChoice) else { return }
    AppSettings.setColorChoice(choice, for: provider)
    onSettingChanged?()
  }

  @objc private func redlineColorChanged(_ sender: NSMenuItem) {
    guard let choice = sender.representedObject as? GaugeColorChoice else { return }
    AppSettings.redlineColor = choice
    onSettingChanged?()
  }

  @objc private func resetSettingsClicked() {
    AppSettings.resetIconStyle()
    onSettingChanged?()
    reloadControls()
  }

  private func makeGaugeView() -> NSView {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 440))
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .noBorder

    // Twelve 52-point slider rows, four headers, section gaps and edge padding.
    // The entire canvas must fit so the last three controls can be scrolled to.
    let contentHeight: CGFloat = 12 * 52 + 4 * 22 + 3 * 10 + 80
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: contentHeight))

    var y: CGFloat = contentHeight - 40

    func addSectionHeader(_ text: String) {
      let label = NSTextField(labelWithString: text)
      label.font = .systemFont(ofSize: 12, weight: .bold)
      label.textColor = .labelColor
      label.frame = NSRect(x: 20, y: y, width: 380, height: 16)
      content.addSubview(label)
      y -= 22
    }

    func addSlider(_ setting: IconSliderSetting) {
      let row = SettingsSliderRow(setting: setting, value: AppSettings.value(for: setting)) { [weak self] val in
        AppSettings.setValue(val, for: setting)
        self?.onSettingChanged?()
      }
      row.frame = NSRect(x: 20, y: y - 40, width: 380, height: 46)
      content.addSubview(row)
      y -= 52
    }

    addSectionHeader("Weekly Hand (Slow Window)")
    addSlider(.weeklyHandLength)
    addSlider(.weeklyHandWidth)
    addSlider(.weeklyHandRadius)

    y -= 10
    addSectionHeader("Short-window Hand (5-hour Window)")
    addSlider(.fastHandLength)
    addSlider(.fastHandWidth)
    addSlider(.fastHandRadius)

    y -= 10
    addSectionHeader("Fable Star Indicator")
    addSlider(.fableStarSize)
    addSlider(.fableStarRadius)

    y -= 10
    addSectionHeader("Scale & Redline Arc")
    addSlider(.scaleDotSize)
    addSlider(.scaleRadius)
    addSlider(.redlineWidth)
    addSlider(.hubSize)

    scrollView.documentView = content
    return scrollView
  }

  private func makeMetersView() -> NSView {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 440))

    var y: CGFloat = 390

    // Provider Swatch
    let swatchTitle = NSTextField(labelWithString: "Provider Swatch")
    swatchTitle.font = .systemFont(ofSize: 12.5, weight: .bold)
    swatchTitle.frame = NSRect(x: 30, y: y, width: 380, height: 18)
    container.addSubview(swatchTitle)
    y -= 28

    let swatchSeg = NSSegmentedControl(labels: ["Color Swatch", "None (Bars Only)"], trackingMode: .selectOne, target: self, action: #selector(meterLabelModeChanged(_:)))
    swatchSeg.selectedSegment = AppSettings.meterLabelMode == .swatch ? 0 : 1
    swatchSeg.frame = NSRect(x: 30, y: y, width: 380, height: 24)
    container.addSubview(swatchSeg)
    y -= 45

    // Fill Style
    let fillTitle = NSTextField(labelWithString: "Meter Fill Style")
    fillTitle.font = .systemFont(ofSize: 12.5, weight: .bold)
    fillTitle.frame = NSRect(x: 30, y: y, width: 380, height: 18)
    container.addSubview(fillTitle)
    y -= 28

    let fillSeg = NSSegmentedControl(labels: ["Fill (Used Quota)", "Empty (Remaining Quota)"], trackingMode: .selectOne, target: self, action: #selector(meterFillModeChanged(_:)))
    fillSeg.selectedSegment = AppSettings.meterFillMode == .fill ? 0 : 1
    fillSeg.frame = NSRect(x: 30, y: y, width: 380, height: 24)
    container.addSubview(fillSeg)
    y -= 45

    // Direction
    let dirTitle = NSTextField(labelWithString: "Meter Direction")
    dirTitle.font = .systemFont(ofSize: 12.5, weight: .bold)
    dirTitle.frame = NSRect(x: 30, y: y, width: 380, height: 18)
    container.addSubview(dirTitle)
    y -= 28

    let dirSeg = NSSegmentedControl(labels: ["Left to Right", "Right to Left"], trackingMode: .selectOne, target: self, action: #selector(meterDirectionChanged(_:)))
    dirSeg.selectedSegment = AppSettings.meterDirection == .leftToRight ? 0 : 1
    dirSeg.frame = NSRect(x: 30, y: y, width: 380, height: 24)
    container.addSubview(dirSeg)
    y -= 50

    // Meter Width Slider
    let widthTitle = NSTextField(labelWithString: "Card Width")
    widthTitle.font = .systemFont(ofSize: 12.5, weight: .bold)
    widthTitle.frame = NSRect(x: 30, y: y, width: 380, height: 18)
    container.addSubview(widthTitle)
    y -= 48

    let sliderRow = SettingsSliderRow(setting: .meterWidth, value: AppSettings.value(for: .meterWidth)) { [weak self] val in
      AppSettings.setValue(val, for: .meterWidth)
      self?.onSettingChanged?()
    }
    sliderRow.frame = NSRect(x: 30, y: y, width: 380, height: 46)
    container.addSubview(sliderRow)

    return container
  }

  @objc private func meterLabelModeChanged(_ sender: NSSegmentedControl) {
    AppSettings.meterLabelMode = sender.selectedSegment == 0 ? .swatch : .none
    onSettingChanged?()
  }

  @objc private func meterFillModeChanged(_ sender: NSSegmentedControl) {
    AppSettings.meterFillMode = sender.selectedSegment == 0 ? .fill : .empty
    onSettingChanged?()
  }

  @objc private func meterDirectionChanged(_ sender: NSSegmentedControl) {
    AppSettings.meterDirection = sender.selectedSegment == 0 ? .leftToRight : .rightToLeft
    onSettingChanged?()
  }

  private func makeUpdatesView() -> NSView {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 380))

    let titleLabel = NSTextField(labelWithString: "Alight")
    titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
    titleLabel.alignment = .center
    titleLabel.frame = NSRect(x: 30, y: 320, width: 380, height: 28)
    container.addSubview(titleLabel)

    let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "development build"
    let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "dev"
    let versionLabel = NSTextField(labelWithString: "Version \(version) (\(build))")
    versionLabel.font = .systemFont(ofSize: 12, weight: .medium)
    versionLabel.textColor = .secondaryLabelColor
    versionLabel.alignment = .center
    versionLabel.frame = NSRect(x: 30, y: 295, width: 380, height: 18)
    container.addSubview(versionLabel)

    let descLabel = NSTextField(wrappingLabelWithString: "A tiny macOS menu bar gauge for Codex, Claude Code, and Antigravity usage pressure.")
    descLabel.font = .systemFont(ofSize: 11, weight: .regular)
    descLabel.textColor = .tertiaryLabelColor
    descLabel.alignment = .center
    descLabel.frame = NSRect(x: 40, y: 245, width: 360, height: 34)
    container.addSubview(descLabel)

    let sep = NSBox(frame: NSRect(x: 40, y: 230, width: 360, height: 1))
    sep.boxType = .separator
    container.addSubview(sep)

    let autoBox = NSButton(checkboxWithTitle: "Install updates automatically", target: self, action: #selector(toggleAutoUpdates(_:)))
    autoBox.state = automaticallyInstallsUpdates ? .on : .off
    autoBox.frame = NSRect(x: 50, y: 185, width: 340, height: 22)
    self.autoUpdateCheckbox = autoBox
    container.addSubview(autoBox)

    let checkNowBtn = NSButton(title: "Check for Updates Now…", target: self, action: #selector(checkNowClicked))
    checkNowBtn.bezelStyle = .rounded
    checkNowBtn.frame = NSRect(x: 45, y: 140, width: 220, height: 32)
    container.addSubview(checkNowBtn)

    let channelLabel = NSTextField(labelWithString: "Release channel: stable (updates.owlandkestrel.com)")
    channelLabel.font = .systemFont(ofSize: 10, weight: .regular)
    channelLabel.textColor = .tertiaryLabelColor
    channelLabel.frame = NSRect(x: 50, y: 100, width: 340, height: 16)
    container.addSubview(channelLabel)

    return container
  }

  @objc private func toggleAutoUpdates(_ sender: NSButton) {
    let enabled = sender.state == .on
    automaticallyInstallsUpdates = enabled
    onAutomaticUpdatesChanged?(enabled)
    onSettingChanged?()
  }

  @objc private func checkNowClicked() {
    onCheckForUpdates?()
  }

  private func reloadControls() {
    // Re-create tabs on reload if reset or settings changed externally
    guard let window else { return }
    setupTabs(for: window)
  }
}
