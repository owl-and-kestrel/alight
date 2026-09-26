import AppKit

// MARK: - Color Swatch Button (Interactive Hover Intent & Click Affordance)

@MainActor
final class ColorSwatchButton: NSControl {
  private let provider: Provider
  private var currentColor: NSColor
  private(set) var isHovered = false
  private var isMenuShowing = false
  private var hoverIntentTimer: Timer?
  var onColorChanged: ((GaugeColorChoice) -> Void)?

  override var isFlipped: Bool { true }

  init(provider: Provider, color: NSColor) {
    self.provider = provider
    self.currentColor = color
    super.init(frame: NSRect(x: 12, y: 4, width: 18, height: 18))
    self.toolTip = "Change \(provider.displayName) color…"
    updateTrackingAreas()
  }

  required init?(coder: NSCoder) { nil }

  func updateColor(_ color: NSColor) {
    self.currentColor = color
    setNeedsDisplay(bounds)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas {
      removeTrackingArea(area)
    }
    let tracking = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(tracking)
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
    setNeedsDisplay(bounds)
    NSCursor.pointingHand.set()

    // Hover intent: dwelling on the swatch opens the color picker after 220ms
    hoverIntentTimer?.invalidate()
    hoverIntentTimer = Timer.scheduledTimer(
      timeInterval: 0.22,
      target: self,
      selector: #selector(handleHoverIntentTimer),
      userInfo: nil,
      repeats: false
    )
  }

  @objc private func handleHoverIntentTimer() {
    guard isHovered, !isMenuShowing else { return }
    showColorMenu()
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
    hoverIntentTimer?.invalidate()
    hoverIntentTimer = nil
    setNeedsDisplay(bounds)
    NSCursor.arrow.set()
  }

  override func mouseDown(with event: NSEvent) {
    hoverIntentTimer?.invalidate()
    hoverIntentTimer = nil
    showColorMenu()
  }

  func showColorMenu() {
    guard !isMenuShowing else { return }
    isMenuShowing = true
    defer { isMenuShowing = false }

    let menu = NSMenu()
    menu.autoenablesItems = false
    let currentChoice = AppSettings.colorChoice(for: provider)
    for choice in GaugeColorChoice.allCases {
      let item = NSMenuItem(title: choice.menuTitle, action: #selector(colorSelected(_:)), keyEquivalent: "")
      item.image = Self.swatchImage(color: choice.nsColor)
      item.representedObject = choice
      item.target = self
      if choice == currentChoice {
        item.state = .on
      }
      menu.addItem(item)
    }
    menu.popUp(
      positioning: menu.item(withTitle: currentChoice.menuTitle),
      at: NSPoint(x: 0, y: bounds.height + 2),
      in: self
    )
  }

  @objc private func colorSelected(_ sender: NSMenuItem) {
    guard let choice = sender.representedObject as? GaugeColorChoice else { return }
    AppSettings.setColorChoice(choice, for: provider)
    currentColor = choice.nsColor
    setNeedsDisplay(bounds)
    onColorChanged?(choice)
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    // When hovered, draw a subtle hover pill background
    if isHovered {
      let hoverPillRect = bounds.insetBy(dx: 0.5, dy: 0.5)
      let pillPath = NSBezierPath(roundedRect: hoverPillRect, xRadius: 4.0, yRadius: 4.0)
      NSColor.quaternaryLabelColor.setFill()
      pillPath.fill()
    }

    let swatchRect = NSRect(x: 2.5, y: 2.5, width: 13, height: 13)
    let swatchPath = NSBezierPath(roundedRect: swatchRect, xRadius: 3.0, yRadius: 3.0)

    // When hovered, draw an accent focus ring around the swatch
    if isHovered {
      let ringRect = swatchRect.insetBy(dx: -1.5, dy: -1.5)
      let ringPath = NSBezierPath(roundedRect: ringRect, xRadius: 4.5, yRadius: 4.5)
      NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
      ringPath.lineWidth = 1.5
      ringPath.stroke()
    }

    currentColor.setFill()
    swatchPath.fill()

    NSColor(white: 0.0, alpha: 0.20).setStroke()
    swatchPath.lineWidth = 0.5
    swatchPath.stroke()

    // Hover dot affordance
    if isHovered {
      let dotRect = NSRect(x: swatchRect.midX - 1.5, y: swatchRect.midY - 1.5, width: 3, height: 3)
      NSColor.white.withAlphaComponent(0.95).setFill()
      NSBezierPath(ovalIn: dotRect).fill()
    }
  }

  static func swatchImage(color: NSColor) -> NSImage {
    let image = NSImage(size: NSSize(width: 12, height: 12))
    image.lockFocus()
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 10, height: 10), xRadius: 2.5, yRadius: 2.5).fill()
    NSColor(white: 0.0, alpha: 0.2).setStroke()
    NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 10, height: 10), xRadius: 2.5, yRadius: 2.5).stroke()
    image.unlockFocus()
    image.isTemplate = false
    return image
  }
}

// MARK: - Provider Header Row View

@MainActor
final class ProviderHeaderRowView: NSView {
  private let provider: Provider
  private let swatchButton: ColorSwatchButton
  private let providerName: String
  private let statusText: String
  private let statusColor: NSColor
  private let canMoveUp: Bool
  private let canMoveDown: Bool
  private var dragStartY: CGFloat?

  var onColorChanged: ((GaugeColorChoice) -> Void)?
  var onMoveUp: (() -> Void)?
  var onMoveDown: (() -> Void)?

  override var isFlipped: Bool { true }

  init(
    provider: Provider,
    color: NSColor,
    result: ProviderResult?,
    canMoveUp: Bool = false,
    canMoveDown: Bool = false,
    onColorChanged: ((GaugeColorChoice) -> Void)? = nil,
    onMoveUp: (() -> Void)? = nil,
    onMoveDown: (() -> Void)? = nil
  ) {
    self.provider = provider
    self.providerName = provider.displayName
    self.canMoveUp = canMoveUp
    self.canMoveDown = canMoveDown
    self.onColorChanged = onColorChanged
    self.onMoveUp = onMoveUp
    self.onMoveDown = onMoveDown

    if let result {
      if result.needsAuth {
        self.statusText = "Sign In Needed"
        self.statusColor = .systemOrange
      } else if result.source == "cached" {
        let age = result.cacheAgeDisplay ?? ""
        self.statusText = age.isEmpty ? "Cached" : "Cached · \(age)"
        self.statusColor = .secondaryLabelColor
      } else if result.ok {
        self.statusText = "Live"
        self.statusColor = .tertiaryLabelColor
      } else {
        self.statusText = "Offline"
        self.statusColor = .secondaryLabelColor
      }
    } else {
      self.statusText = "Offline"
      self.statusColor = .secondaryLabelColor
    }

    self.swatchButton = ColorSwatchButton(provider: provider, color: color)

    super.init(frame: NSRect(x: 0, y: 0, width: 286, height: 26))

    swatchButton.onColorChanged = { [weak self] choice in
      self?.onColorChanged?(choice)
    }
    addSubview(swatchButton)

    // Provider name label
    let titleLabel = NSTextField(labelWithString: providerName)
    titleLabel.font = .systemFont(ofSize: 12.5, weight: .bold)
    titleLabel.textColor = .labelColor
    titleLabel.frame = NSRect(x: 32, y: 5, width: 110, height: 16)
    addSubview(titleLabel)

    // Status / cache label (negative space cleanly reserved)
    let statusLabel = NSTextField(labelWithString: statusText)
    statusLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
    statusLabel.textColor = statusColor
    statusLabel.alignment = .right
    statusLabel.frame = NSRect(x: 142, y: 5, width: 100, height: 16)
    addSubview(statusLabel)

    // Clickable reorder buttons (▲ / ▼)
    if canMoveUp {
      let upBtn = MenuIconButton(
        frame: NSRect(x: 246, y: 3, width: 16, height: 20),
        symbolName: "chevron.up",
        toolTip: "Move \(provider.displayName) up",
        onClick: onMoveUp
      )
      addSubview(upBtn)
    }

    if canMoveDown {
      let downBtn = MenuIconButton(
        frame: NSRect(x: 265, y: 3, width: 16, height: 20),
        symbolName: "chevron.down",
        toolTip: "Move \(provider.displayName) down",
        onClick: onMoveDown
      )
      addSubview(downBtn)
    }
  }

  required init?(coder: NSCoder) {
    nil
  }

  // Click-and-drag in the menu row to reorder
  override func mouseDown(with event: NSEvent) {
    dragStartY = convert(event.locationInWindow, from: nil).y
  }

  override func mouseDragged(with event: NSEvent) {
    guard let startY = dragStartY else { return }
    let currentY = convert(event.locationInWindow, from: nil).y
    let delta = currentY - startY
    if delta < -14 && canMoveUp {
      dragStartY = nil
      onMoveUp?()
    } else if delta > 14 && canMoveDown {
      dragStartY = nil
      onMoveDown?()
    }
  }

  override func mouseUp(with event: NSEvent) {
    dragStartY = nil
  }
}

// MARK: - Usage Window Row View

@MainActor
final class UsageWindowRowView: NSView {
  private let usageWindow: UsageWindow
  private let accentColor: NSColor
  private let fillMode: MeterFillMode
  private let now: Date
  private var liveTimer: Timer?
  private var countdownLabel: NSTextField?

  override var isFlipped: Bool { true }

  init(
    window: UsageWindow,
    accentColor: NSColor,
    fillMode: MeterFillMode,
    now: Date = Date()
  ) {
    self.usageWindow = window
    self.accentColor = accentColor
    self.fillMode = fillMode
    self.now = now

    super.init(frame: NSRect(x: 0, y: 0, width: 286, height: 36))

    self.toolTip = "Resets \(window.resetDescription(now: now))"

    // 1. Window label on top left
    let labelX: CGFloat = window.visualStyle == .outerStar ? 28 : 18
    let labelLabel = NSTextField(labelWithString: window.label)
    labelLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
    labelLabel.textColor = .labelColor
    labelLabel.frame = NSRect(x: labelX, y: 3, width: 116 - (labelX - 18), height: 16)
    addSubview(labelLabel)

    // 2. Remaining % and Pace status on top right
    let statsLabel = NSTextField()
    statsLabel.isBezeled = false
    statsLabel.drawsBackground = false
    statsLabel.isEditable = false
    statsLabel.isSelectable = false
    statsLabel.alignment = .right
    statsLabel.attributedStringValue = makeStatsAttributedString()
    statsLabel.frame = NSRect(x: 134, y: 3, width: 138, height: 16)
    addSubview(statsLabel)

    // 3. DD:HH:MM:SS Countdown on bottom right
    let formattedCountdown = Self.formatCountdown(resetAt: window.resetAt, now: now)
    let countdown = NSTextField(labelWithString: formattedCountdown)
    countdown.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
    countdown.textColor = .secondaryLabelColor
    countdown.alignment = .right
    countdown.frame = NSRect(x: 160, y: 20, width: 112, height: 14)
    self.countdownLabel = countdown
    addSubview(countdown)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil {
      liveTimer?.invalidate()
      liveTimer = Timer.scheduledTimer(
        timeInterval: 1.0,
        target: self,
        selector: #selector(tickLiveCountdown),
        userInfo: nil,
        repeats: true
      )
    } else {
      liveTimer?.invalidate()
      liveTimer = nil
    }
  }

  @objc private func tickLiveCountdown() {
    countdownLabel?.stringValue = Self.formatCountdown(resetAt: usageWindow.resetAt, now: Date())
  }

  nonisolated static func formatCountdown(resetAt: Date, now: Date) -> String {
    let diff = resetAt.timeIntervalSince(now)
    guard diff > 0 else { return "00:00:00:00" }
    let totalSeconds = Int(diff.rounded(.down))
    let days = totalSeconds / 86400
    let hours = (totalSeconds % 86400) / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    return String(format: "%02d:%02d:%02d:%02d", days, hours, minutes, seconds)
  }

  private func makeStatsAttributedString() -> NSAttributedString {
    let result = NSMutableAttributedString()

    // Remaining percentage
    let remaining = "\(usageWindow.remainingDisplay) left"
    let remainingAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
      .foregroundColor: usageWindow.remainingPercent <= 0 ? NSColor.secondaryLabelColor : NSColor.labelColor
    ]
    result.append(NSAttributedString(string: remaining, attributes: remainingAttrs))

    // Subtle bullet separator
    let dotAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 10, weight: .regular),
      .foregroundColor: NSColor.tertiaryLabelColor
    ]
    result.append(NSAttributedString(string: "  ·  ", attributes: dotAttrs))

    // Pace badge text & color
    let (paceText, paceColor) = paceDisplay()
    let paceAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
      .foregroundColor: paceColor
    ]
    result.append(NSAttributedString(string: paceText, attributes: paceAttrs))

    return result
  }

  private func paceDisplay() -> (String, NSColor) {
    let band = usageWindow.band
    let roundedPressure = Int(usageWindow.pressurePercent.rounded())

    switch band {
    case .high:
      let label = roundedPressure > 0 ? "+\(roundedPressure)% slack" : "Slack"
      return (label, band.nsColor)
    case .good:
      return ("On pace", band.nsColor)
    case .low:
      let label = roundedPressure != 0 ? "\(roundedPressure)% hot" : "Hot"
      return (label, band.nsColor)
    case .unknown:
      return ("Unknown", band.nsColor)
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    // Optional Fable 4-pointed star
    if usageWindow.visualStyle == .outerStar {
      drawFableStar(at: NSPoint(x: 21, y: 11))
    }

    // Progress Bar Track
    let trackRect = NSRect(x: 18, y: 24, width: 136, height: 5.5)
    let trackRadius: CGFloat = 2.75
    let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: trackRadius, yRadius: trackRadius)

    accentColor.withAlphaComponent(0.20).setFill()
    trackPath.fill()

    // Filled bar
    let fraction: CGFloat
    switch fillMode {
    case .fill:
      fraction = CGFloat(min(1.0, max(0.0, usageWindow.usedPercent / 100.0)))
    case .empty:
      fraction = CGFloat(min(1.0, max(0.0, usageWindow.remainingPercent / 100.0)))
    }

    if fraction > 0.01 {
      let fillWidth = max(trackRadius * 2, trackRect.width * fraction)
      let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY, width: fillWidth, height: trackRect.height)
      let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: trackRadius, yRadius: trackRadius)
      accentColor.setFill()
      fillPath.fill()
    }

    // Clock pace indicator tick
    let paceFraction: CGFloat
    switch fillMode {
    case .fill:
      paceFraction = CGFloat(min(1.0, max(0.0, 1.0 - usageWindow.expectedRemainingPercent / 100.0)))
    case .empty:
      paceFraction = CGFloat(min(1.0, max(0.0, usageWindow.expectedRemainingPercent / 100.0)))
    }

    let tickX = trackRect.minX + trackRect.width * paceFraction
    let tickRect = NSRect(x: tickX - 0.75, y: trackRect.minY - 1.25, width: 1.5, height: trackRect.height + 2.5)

    // Subtle shadow around the tick for contrast
    NSColor(white: 0.0, alpha: 0.35).setFill()
    NSBezierPath(roundedRect: tickRect.insetBy(dx: -0.5, dy: -0.5), xRadius: 0.75, yRadius: 0.75).fill()

    // Crisp light tick
    NSColor(white: 0.95, alpha: 0.95).setFill()
    NSBezierPath(roundedRect: tickRect, xRadius: 0.75, yRadius: 0.75).fill()
  }

  private func drawFableStar(at center: NSPoint) {
    let vertices: [(CGFloat, CGFloat)] = [
      (0, 4.0), (1.0, 1.0), (4.0, 0), (1.0, -1.0),
      (0, -4.0), (-1.0, -1.0), (-4.0, 0), (-1.0, 1.0)
    ]
    let path = NSBezierPath()
    path.move(to: NSPoint(x: center.x + vertices[0].0, y: center.y + vertices[0].1))
    for v in vertices.dropFirst() {
      path.line(to: NSPoint(x: center.x + v.0, y: center.y + v.1))
    }
    path.close()
    accentColor.setFill()
    path.fill()
  }
}

// MARK: - Provider Note Row View (Cached details or warnings)

@MainActor
final class ProviderNoteRowView: NSView {
  override var isFlipped: Bool { true }

  init(text: String) {
    super.init(frame: NSRect(x: 0, y: 0, width: 286, height: 16))

    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 10, weight: .regular)
    label.textColor = .tertiaryLabelColor
    label.frame = NSRect(x: 18, y: 1, width: 254, height: 14)
    addSubview(label)
  }

  required init?(coder: NSCoder) {
    nil
  }
}

// MARK: - Provider Status Row View (Empty or Unavailable Reason)

@MainActor
final class ProviderStatusRowView: NSView {
  override var isFlipped: Bool { true }

  init(reason: String) {
    super.init(frame: NSRect(x: 0, y: 0, width: 286, height: 22))

    let label = NSTextField(labelWithString: reason)
    label.font = .systemFont(ofSize: 11, weight: .regular)
    label.textColor = .secondaryLabelColor
    label.frame = NSRect(x: 18, y: 3, width: 254, height: 16)
    addSubview(label)
  }

  required init?(coder: NSCoder) {
    nil
  }
}

// MARK: - Menu Icon Button (Interactive Hover Intent & Direct Click)

@MainActor
final class MenuIconButton: NSControl {
  private let symbolName: String
  private let fallbackSymbolName: String?
  private let buttonToolTip: String
  private(set) var isHovered = false
  private(set) var isPressed = false
  private var isActionRunning = false
  private var hoverIntentTimer: Timer?

  var onClick: (() -> Void)?
  var onHoverIntent: (() -> Void)?

  override var isFlipped: Bool { true }

  init(
    frame: NSRect,
    symbolName: String,
    fallbackSymbolName: String? = nil,
    toolTip: String,
    onClick: (() -> Void)? = nil,
    onHoverIntent: (() -> Void)? = nil
  ) {
    self.symbolName = symbolName
    self.fallbackSymbolName = fallbackSymbolName
    self.buttonToolTip = toolTip
    self.onClick = onClick
    self.onHoverIntent = onHoverIntent

    super.init(frame: frame)

    self.toolTip = toolTip
    updateTrackingAreas()
  }

  required init?(coder: NSCoder) { nil }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas {
      removeTrackingArea(area)
    }
    let tracking = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(tracking)
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
    setNeedsDisplay(bounds)
    NSCursor.pointingHand.set()

    // Hover intent: trigger onHoverIntent if the user hovers for 220ms
    if onHoverIntent != nil {
      hoverIntentTimer?.invalidate()
      hoverIntentTimer = Timer.scheduledTimer(
        timeInterval: 0.22,
        target: self,
        selector: #selector(handleHoverIntentTimer),
        userInfo: nil,
        repeats: false
      )
    }
  }

  @objc private func handleHoverIntentTimer() {
    guard isHovered, !isActionRunning else { return }
    isActionRunning = true
    onHoverIntent?()
    isActionRunning = false
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
    isPressed = false
    hoverIntentTimer?.invalidate()
    hoverIntentTimer = nil
    setNeedsDisplay(bounds)
    NSCursor.arrow.set()
  }

  override func mouseDown(with event: NSEvent) {
    hoverIntentTimer?.invalidate()
    hoverIntentTimer = nil
    isPressed = true
    setNeedsDisplay(bounds)

    guard !isActionRunning else { return }
    isActionRunning = true
    onClick?()
    isActionRunning = false

    isPressed = false
    setNeedsDisplay(bounds)
  }

  override func mouseUp(with event: NSEvent) {
    isPressed = false
    setNeedsDisplay(bounds)
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    // Pill background on hover or press
    if isPressed {
      let pillRect = bounds.insetBy(dx: 1.0, dy: 1.0)
      let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 4.5, yRadius: 4.5)
      NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
      pillPath.fill()

      NSColor.separatorColor.withAlphaComponent(0.30).setStroke()
      pillPath.lineWidth = 0.5
      pillPath.stroke()
    } else if isHovered {
      let pillRect = bounds.insetBy(dx: 1.0, dy: 1.0)
      let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 4.5, yRadius: 4.5)
      NSColor.quaternaryLabelColor.setFill()
      pillPath.fill()

      NSColor.separatorColor.withAlphaComponent(0.20).setStroke()
      pillPath.lineWidth = 0.5
      pillPath.stroke()
    }

    // Draw SF Symbol with state-matched color
    let tintColor: NSColor
    if isPressed {
      tintColor = .controlAccentColor
    } else if isHovered {
      tintColor = .labelColor
    } else {
      tintColor = .secondaryLabelColor
    }

    let config = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .medium)
      .applying(.init(hierarchicalColor: tintColor))
    let rawImage = (NSImage(systemSymbolName: symbolName, accessibilityDescription: buttonToolTip)
      ?? fallbackSymbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: buttonToolTip) })
    guard let rawImage else { return }

    let image = rawImage.withSymbolConfiguration(config) ?? rawImage
    let imageRect = NSRect(
      x: (bounds.width - image.size.width) / 2.0,
      y: (bounds.height - image.size.height) / 2.0,
      width: image.size.width,
      height: image.size.height
    )
    image.draw(in: imageRect)
  }
}

// MARK: - Menu Footer Row View

@MainActor
final class MenuFooterRowView: NSView {
  private let refreshButton: MenuIconButton
  private let gearButton: MenuIconButton

  override var isFlipped: Bool { true }

  init(
    statusText: String,
    onRefresh: @escaping () -> Void,
    onGearClick: @escaping () -> Void
  ) {
    // 1. Refresh button (left)
    self.refreshButton = MenuIconButton(
      frame: NSRect(x: 8, y: 2, width: 22, height: 22),
      symbolName: "arrow.clockwise",
      toolTip: "Refresh usage readings now (⌘R)",
      onClick: onRefresh
    )

    // 2. Gear / Settings button (right)
    self.gearButton = MenuIconButton(
      frame: NSRect(x: 256, y: 2, width: 22, height: 22),
      symbolName: "gearshape.fill",
      fallbackSymbolName: "gearshape",
      toolTip: "Settings… (⌘,)",
      onClick: onGearClick
    )

    super.init(frame: NSRect(x: 0, y: 0, width: 286, height: 26))

    addSubview(refreshButton)
    addSubview(gearButton)

    // 3. Status label (middle)
    let label = NSTextField(labelWithString: statusText)
    label.font = .systemFont(ofSize: 10, weight: .regular)
    label.textColor = .tertiaryLabelColor
    label.alignment = .center
    label.frame = NSRect(x: 32, y: 5, width: 222, height: 16)
    addSubview(label)
  }

  required init?(coder: NSCoder) { nil }
}
