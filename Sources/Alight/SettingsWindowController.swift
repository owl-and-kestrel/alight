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

  /// Content width of the settings tabs.
  private static let contentWidth: CGFloat = 440
  /// Inset from the content edge for titles, subtitles, and separators.
  private static let contentPad: CGFloat = 30

  /// A centred, single-line label that advances the vertical cursor.
  private func addCenteredLabel(
    to container: NSView,
    cursor: inout CGFloat,
    text: String,
    font: NSFont,
    height: CGFloat,
    gap: CGFloat,
    color: NSColor = .labelColor,
    wrapping: Bool = false
  ) {
    let label = wrapping
      ? NSTextField(wrappingLabelWithString: text)
      : NSTextField(labelWithString: text)
    label.font = font
    label.textColor = color
    label.alignment = .center
    label.frame = NSRect(
      x: Self.contentPad,
      y: cursor - height,
      width: Self.contentWidth - 2 * Self.contentPad,
      height: height
    )
    container.addSubview(label)
    cursor -= height + gap
  }

  /// Places a control centred horizontally in the tab and advances the cursor.
  private func addCentered(
    _ control: NSView,
    in container: NSView,
    cursor: inout CGFloat,
    width: CGFloat,
    height: CGFloat,
    gap: CGFloat
  ) {
    control.frame = NSRect(
      x: (Self.contentWidth - width) / 2,
      y: cursor - height,
      width: width,
      height: height
    )
    container.addSubview(control)
    cursor -= height + gap
  }

  private func addSeparator(in container: NSView, cursor: inout CGFloat, gap: CGFloat = 16) {
    let sep = NSBox(frame: NSRect(
      x: Self.contentPad,
      y: cursor - 1,
      width: Self.contentWidth - 2 * Self.contentPad,
      height: 1
    ))
    sep.boxType = .separator
    container.addSubview(sep)
    cursor -= 1 + gap
  }

  private func makeGeneralView() -> NSView {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 440))
    var cursor: CGFloat = 396

    addCenteredLabel(
      to: container, cursor: &cursor,
      text: "Menu Bar Display Mode",
      font: .systemFont(ofSize: 13, weight: .bold),
      height: 18, gap: 6
    )
    addCenteredLabel(
      to: container, cursor: &cursor,
      text: "Choose whether Alight displays the circular pace gauge or horizontal provider meter cards in the macOS menu bar.",
      font: .systemFont(ofSize: 11, weight: .regular),
      height: 32, gap: 8, color: .secondaryLabelColor, wrapping: true
    )

    let modeSeg = NSSegmentedControl(labels: ["Gauge Dial", "Provider Meters"], trackingMode: .selectOne, target: self, action: #selector(displayModeChanged(_:)))
    modeSeg.selectedSegment = AppSettings.displayMode == .gauge ? 0 : 1
    addCentered(modeSeg, in: container, cursor: &cursor, width: 380, height: 24, gap: 16)

    addSeparator(in: container, cursor: &cursor)

    addCenteredLabel(
      to: container, cursor: &cursor,
      text: "Provider Colors",
      font: .systemFont(ofSize: 13, weight: .bold),
      height: 18, gap: 6
    )
    addCenteredLabel(
      to: container, cursor: &cursor,
      text: "Select accent colors used on the menu bar icon and info cards.",
      font: .systemFont(ofSize: 11, weight: .regular),
      height: 16, gap: 10, color: .secondaryLabelColor
    )

    for provider in Provider.allCases {
      addColorRow(
        label: "\(provider.displayName):",
        popup: makeColorPopUp(for: provider, frame: .zero),
        in: container,
        cursor: &cursor,
        gap: 8
      )
    }

    let redlinePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    for choice in GaugeColorChoice.allCases {
      let item = NSMenuItem(title: choice.menuTitle, action: #selector(redlineColorChanged(_:)), keyEquivalent: "")
      item.image = ColorSwatchButton.swatchImage(color: choice.nsColor)
      item.representedObject = choice
      item.target = self
      redlinePopUp.menu?.addItem(item)
    }
    redlinePopUp.selectItem(withTitle: AppSettings.redlineColor.menuTitle)
    addColorRow(label: "Redline Arc:", popup: redlinePopUp, in: container, cursor: &cursor, gap: 16)

    addSeparator(in: container, cursor: &cursor)

    // Reset & Quit, presented as one centred pair.
    let buttonWidth: CGFloat = 140
    let quitWidth: CGFloat = 110
    let pairWidth = buttonWidth + 10 + quitWidth
    let pairX = (Self.contentWidth - pairWidth) / 2
    let buttonY = cursor - 28

    let resetBtn = NSButton(title: "Reset Settings", target: self, action: #selector(resetSettingsClicked))
    resetBtn.bezelStyle = .rounded
    resetBtn.frame = NSRect(x: pairX, y: buttonY, width: buttonWidth, height: 28)
    container.addSubview(resetBtn)

    let quitBtn = NSButton(title: "Quit Alight", target: self, action: #selector(quitClicked))
    quitBtn.bezelStyle = .rounded
    quitBtn.frame = NSRect(x: pairX + buttonWidth + 10, y: buttonY, width: quitWidth, height: 28)
    container.addSubview(quitBtn)

    return container
  }

  /// A centred label + popup pair, so the color rows sit in the middle of the
  /// tab instead of hanging off the left edge.
  private func addColorRow(
    label labelText: String,
    popup: NSPopUpButton,
    in container: NSView,
    cursor: inout CGFloat,
    gap: CGFloat
  ) {
    let labelWidth: CGFloat = 100
    let popupWidth: CGFloat = 150
    let pairWidth = labelWidth + 6 + popupWidth
    let pairX = (Self.contentWidth - pairWidth) / 2
    let rowHeight: CGFloat = 24

    let label = NSTextField(labelWithString: labelText)
    label.font = .systemFont(ofSize: 12, weight: .medium)
    label.alignment = .right
    label.frame = NSRect(x: pairX, y: cursor - rowHeight + 3, width: labelWidth, height: 18)
    container.addSubview(label)

    popup.frame = NSRect(x: pairX + labelWidth + 6, y: cursor - rowHeight, width: popupWidth, height: rowHeight)
    container.addSubview(popup)

    cursor -= rowHeight + gap
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
      label.alignment = .center
      label.frame = NSRect(x: 20, y: y, width: 380, height: 16)
      content.addSubview(label)
      y -= 22
    }

    func addSlider(_ setting: IconSliderSetting) {
      let row = SettingsSliderRow(setting: setting, value: AppSettings.value(for: setting), width: 380) { [weak self] val in
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
    let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 440))
    var cursor: CGFloat = 389

    // Which providers draw a meter card in the menu bar.
    addCenteredLabel(
      to: container, cursor: &cursor,
      text: "Visible Meters",
      font: .systemFont(ofSize: 12.5, weight: .bold),
      height: 18, gap: 4
    )

    let boxWidth: CGFloat = 100
    let boxHeight: CGFloat = 22
    let boxRow = NSView(frame: .zero)
    for (index, provider) in Provider.allCases.enumerated() {
      let box = NSButton(
        checkboxWithTitle: provider.displayName,
        target: self,
        action: #selector(meterVisibilityChanged(_:))
      )
      box.state = AppSettings.meterVisible(provider) ? .on : .off
      box.identifier = NSUserInterfaceItemIdentifier(provider.rawValue)
      box.frame = NSRect(x: CGFloat(index) * (boxWidth + 5), y: 0, width: boxWidth, height: boxHeight)
      boxRow.addSubview(box)
    }
    addCentered(boxRow, in: container, cursor: &cursor, width: boxWidth * 3 + 10, height: boxHeight, gap: 22)

    addCenteredLabel(
      to: container, cursor: &cursor,
      text: "Provider Swatch",
      font: .systemFont(ofSize: 12.5, weight: .bold),
      height: 18, gap: 4
    )
    let swatchSeg = NSSegmentedControl(labels: ["Color Swatch", "None (Bars Only)"], trackingMode: .selectOne, target: self, action: #selector(meterLabelModeChanged(_:)))
    swatchSeg.selectedSegment = AppSettings.meterLabelMode == .swatch ? 0 : 1
    addCentered(swatchSeg, in: container, cursor: &cursor, width: 380, height: 24, gap: 22)

    addCenteredLabel(
      to: container, cursor: &cursor,
      text: "Meter Fill Style",
      font: .systemFont(ofSize: 12.5, weight: .bold),
      height: 18, gap: 4
    )
    let fillSeg = NSSegmentedControl(labels: ["Fill (Used Quota)", "Empty (Remaining Quota)"], trackingMode: .selectOne, target: self, action: #selector(meterFillModeChanged(_:)))
    fillSeg.selectedSegment = AppSettings.meterFillMode == .fill ? 0 : 1
    addCentered(fillSeg, in: container, cursor: &cursor, width: 380, height: 24, gap: 22)

    addCenteredLabel(
      to: container, cursor: &cursor,
      text: "Meter Direction",
      font: .systemFont(ofSize: 12.5, weight: .bold),
      height: 18, gap: 4
    )
    let dirSeg = NSSegmentedControl(labels: ["Left to Right", "Right to Left"], trackingMode: .selectOne, target: self, action: #selector(meterDirectionChanged(_:)))
    dirSeg.selectedSegment = AppSettings.meterDirection == .leftToRight ? 0 : 1
    addCentered(dirSeg, in: container, cursor: &cursor, width: 380, height: 24, gap: 22)

    addCenteredLabel(
      to: container, cursor: &cursor,
      text: "Card Width",
      font: .systemFont(ofSize: 12.5, weight: .bold),
      height: 18, gap: 4
    )
    let sliderRow = SettingsSliderRow(setting: .meterWidth, value: AppSettings.value(for: .meterWidth), width: 380) { [weak self] val in
      AppSettings.setValue(val, for: .meterWidth)
      self?.onSettingChanged?()
    }
    addCentered(sliderRow, in: container, cursor: &cursor, width: 380, height: 46, gap: 22)

    return container
  }

  @objc private func meterVisibilityChanged(_ sender: NSButton) {
    guard
      let rawValue = sender.identifier?.rawValue,
      let provider = Provider(rawValue: rawValue)
    else { return }
    AppSettings.setMeterVisible(sender.state == .on, for: provider)
    onSettingChanged?()
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
    autoBox.sizeToFit()
    let autoWidth = autoBox.frame.width
    autoBox.frame = NSRect(x: (Self.contentWidth - autoWidth) / 2, y: 185, width: autoWidth, height: 22)
    self.autoUpdateCheckbox = autoBox
    container.addSubview(autoBox)

    let checkNowBtn = NSButton(title: "Check for Updates Now…", target: self, action: #selector(checkNowClicked))
    checkNowBtn.bezelStyle = .rounded
    checkNowBtn.frame = NSRect(x: (Self.contentWidth - 220) / 2, y: 140, width: 220, height: 32)
    container.addSubview(checkNowBtn)

    let channelLabel = NSTextField(labelWithString: "Release channel: stable (updates.owlandkestrel.com)")
    channelLabel.font = .systemFont(ofSize: 10, weight: .regular)
    channelLabel.textColor = .tertiaryLabelColor
    channelLabel.alignment = .center
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
