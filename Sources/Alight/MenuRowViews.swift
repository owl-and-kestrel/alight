import AppKit

/// Native menus use event tracking mode. Their countdown and hover timers must
/// continue while the menu owns the run loop, including nested color menus.
@MainActor
enum MenuTrackingTimer {
  static func scheduled(timeInterval: TimeInterval, target: Any, selector: Selector,
    userInfo: Any?, repeats: Bool) -> Timer {
    let timer = Timer(timeInterval: timeInterval, target: target, selector: selector,
      userInfo: userInfo, repeats: repeats)
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .eventTracking)
    return timer
  }
}

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
    hoverIntentTimer = MenuTrackingTimer.scheduled(
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
  private var canMoveUp: Bool
  private var canMoveDown: Bool
  private let moveUpButton: MenuIconButton
  private let moveDownButton: MenuIconButton
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

    // Clickable reorder buttons (▲ / ▼). Both are built up front so a
    // reorder can reveal/hide them without rebuilding the row.
    let moveUp = MenuIconButton(
      frame: NSRect(x: 246, y: 3, width: 16, height: 20),
      symbolName: "chevron.up",
      toolTip: "Move \(provider.displayName) up",
      onClick: onMoveUp
    )
    let moveDown = MenuIconButton(
      frame: NSRect(x: 265, y: 3, width: 16, height: 20),
      symbolName: "chevron.down",
      toolTip: "Move \(provider.displayName) down",
      onClick: onMoveDown
    )
    moveUp.isHidden = !canMoveUp
    moveDown.isHidden = !canMoveDown
    self.moveUpButton = moveUp
    self.moveDownButton = moveDown

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
    // Cached hands hide the latest attempt's reason (for example, that Claude
    // polling stopped); hovering the status shows it.
    if result?.source == "cached" {
      statusLabel.toolTip = result?.error
    }
    addSubview(statusLabel)

    addSubview(moveUpButton)
    addSubview(moveDownButton)
  }

  required init?(coder: NSCoder) {
    nil
  }

  /// Shows or hides the chevrons after a reorder changes the row's position.
  func updateMoveLimits(canMoveUp: Bool, canMoveDown: Bool) {
    self.canMoveUp = canMoveUp
    self.canMoveDown = canMoveDown
    moveUpButton.isHidden = !canMoveUp
    moveDownButton.isHidden = !canMoveDown
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
      liveTimer = MenuTrackingTimer.scheduled(
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

  /// A reason wraps onto a second line, so its actionable end (such as "then
  /// Refresh") stays visible; anything longer is truncated and the full text
  /// is the tooltip.
  init(reason: String) {
    let label = NSTextField(wrappingLabelWithString: reason)
    label.font = .systemFont(ofSize: 11, weight: .regular)
    label.textColor = .secondaryLabelColor
    label.maximumNumberOfLines = 2
    label.cell?.truncatesLastVisibleLine = true
    label.preferredMaxLayoutWidth = Self.textWidth
    let lineHeight: CGFloat = 16
    let fitted = label.sizeThatFits(NSSize(width: Self.textWidth, height: .greatestFiniteMagnitude)).height
    let textHeight = fitted > lineHeight + 1 ? 2 * lineHeight - 2 : lineHeight
    super.init(frame: NSRect(x: 0, y: 0, width: 286, height: textHeight + 6))

    label.frame = NSRect(x: 18, y: 3, width: Self.textWidth, height: textHeight)
    addSubview(label)
    toolTip = reason
  }

  private static let textWidth: CGFloat = 254

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
      hoverIntentTimer = MenuTrackingTimer.scheduled(
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

// MARK: - Sign-in Row View

/// One clickable row that starts a provider's CLI login flow. It stands in for
/// the menu's plain "Sign in to …" item so the whole provider section can live
/// inside a single reorderable view.
@MainActor
final class SignInRowView: NSView {
  private let titleLabel: NSTextField
  private var isHovered = false

  var onClick: (() -> Void)?

  override var isFlipped: Bool { true }

  init(title: String, onClick: (() -> Void)? = nil) {
    self.onClick = onClick
    self.titleLabel = NSTextField(labelWithString: title)
    super.init(frame: NSRect(x: 0, y: 0, width: 286, height: 26))

    titleLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
    titleLabel.textColor = .labelColor
    titleLabel.frame = NSRect(x: 30, y: 5, width: 250, height: 16)
    addSubview(titleLabel)
    updateTrackingAreas()
  }

  required init?(coder: NSCoder) { nil }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas {
      removeTrackingArea(area)
    }
    addTrackingArea(NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    ))
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
    setNeedsDisplay(bounds)
    NSCursor.pointingHand.set()
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
    setNeedsDisplay(bounds)
    NSCursor.arrow.set()
  }

  override func mouseDown(with event: NSEvent) {
    onClick?()
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    if isHovered {
      let pill = bounds.insetBy(dx: 1.0, dy: 1.0)
      NSColor.quaternaryLabelColor.setFill()
      NSBezierPath(roundedRect: pill, xRadius: 4.0, yRadius: 4.0).fill()
    }

    let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
    if let symbol = NSImage(
      systemSymbolName: "person.crop.circle.badge.plus",
      accessibilityDescription: "Sign In"
    )?.withSymbolConfiguration(config) {
      let symbolRect = NSRect(
        x: 10,
        y: (bounds.height - symbol.size.height) / 2,
        width: symbol.size.width,
        height: symbol.size.height
      )
      symbol.draw(in: symbolRect)
    }
  }
}

// MARK: - Provider Section View

/// Everything the dropdown shows for one provider, stacked as a single view:
/// the header row (swatch, name, status, reorder chevrons), one row per limit
/// window (or an unavailable status row), and an optional sign-in row.
///
/// Keeping a provider in one view is what lets the list reorder with an
/// animation instead of asking NSMenu to re-lay-out individual items.
@MainActor
final class ProviderSectionView: NSView {
  override var isFlipped: Bool { true }

  let provider: Provider
  private(set) var header: ProviderHeaderRowView

  init(
    provider: Provider,
    color: NSColor,
    result: ProviderResult?,
    fillMode: MeterFillMode,
    now: Date = Date(),
    onColorChanged: ((GaugeColorChoice) -> Void)? = nil,
    onMoveUp: (() -> Void)? = nil,
    onMoveDown: (() -> Void)? = nil,
    onSignIn: (() -> Void)? = nil
  ) {
    self.provider = provider
    self.header = ProviderHeaderRowView(
      provider: provider,
      color: color,
      result: result,
      canMoveUp: false,
      canMoveDown: false,
      onColorChanged: onColorChanged,
      onMoveUp: onMoveUp,
      onMoveDown: onMoveDown
    )
    super.init(frame: NSRect(x: 0, y: 0, width: 286, height: 0))

    var height: CGFloat = 0
    func append(_ row: NSView) {
      row.frame = NSRect(x: 0, y: height, width: 286, height: row.frame.height)
      addSubview(row)
      height += row.frame.height
    }

    append(header)

    if let result, result.ok, !result.windows.isEmpty {
      for window in result.windows {
        append(UsageWindowRowView(window: window, accentColor: color, fillMode: fillMode, now: now))
      }
    } else {
      append(ProviderStatusRowView(reason: result?.error ?? "Usage unavailable"))
    }

    if result?.needsAuth == true {
      append(SignInRowView(title: "Sign in to \(provider.displayName)…", onClick: onSignIn))
    }

    frame = NSRect(x: 0, y: 0, width: 286, height: height)
  }

  required init?(coder: NSCoder) { nil }

  func updateMoveLimits(canMoveUp: Bool, canMoveDown: Bool) {
    header.updateMoveLimits(canMoveUp: canMoveUp, canMoveDown: canMoveDown)
  }
}

// MARK: - Provider Sections Container

/// Stacks every provider section with a hairline separator between them.
///
/// Reordering animates: sections slide to their new slots while the sections
/// being passed over dissolve for the duration of the slide (two rows of text
/// can't trade places vertically without crossing, and crossing text would
/// read as a glitch). The total height never changes, so the open menu keeps
/// its size throughout.
@MainActor
final class ProviderSectionsView: NSView {
  static let width: CGFloat = 286
  /// Vertical space reserved between two sections, hairline included.
  static let separatorHeight: CGFloat = 9
  static let slideDuration: TimeInterval = 0.18
  static let fadeDuration: TimeInterval = 0.14

  override var isFlipped: Bool { true }

  /// Sections in display order (top to bottom).
  private(set) var sections: [ProviderSectionView] = []
  private var separators: [NSBox] = []
  private var animationGeneration = 0

  var totalHeight: CGFloat { currentSectionFrames.last?.maxY ?? 0 }

  /// Replaces the whole list, laying it out without animation.
  func setSections(_ newSections: [ProviderSectionView]) {
    animationGeneration += 1
    for subview in subviews {
      subview.removeFromSuperview()
    }

    sections = newSections
    for section in newSections {
      section.alphaValue = 1
      addSubview(section)
    }

    separators = newSections.count > 1
      ? (0..<(newSections.count - 1)).map { _ in
        let hairline = NSBox(frame: .zero)
        hairline.boxType = .separator
        addSubview(hairline)
        return hairline
      }
      : []

    updateMoveLimits()
    applyLayout()
  }

  /// Shows or hides the reorder chevrons, which depend on position.
  func updateMoveLimits() {
    for (index, section) in sections.enumerated() {
      section.updateMoveLimits(
        canMoveUp: index > 0,
        canMoveDown: index < sections.count - 1
      )
    }
  }

  /// Reorders the sections to match `providers`, animating when asked.
  /// - Parameters:
  ///   - providers: the new display order.
  ///   - movedProvider: the provider the user acted on; it stays solid while
  ///     the sections it passes dissolve.
  func applyOrder(_ providers: [Provider], moving movedProvider: Provider? = nil, animated: Bool) {
    let order = providers.compactMap { provider in sections.first { $0.provider == provider } }
    guard order.count == sections.count, order.count == providers.count else { return }
    // Every section appears exactly once (no duplicate providers in the list).
    guard order.allSatisfy({ section in order.lazy.filter({ $0 === section }).count == 1 }) else { return }

    let previous = sections
    let previousIndex: [ObjectIdentifier: Int] = Dictionary(
      uniqueKeysWithValues: previous.enumerated().map { (ObjectIdentifier($0.element), $0.offset) }
    )
    sections = order

    let moved = movedProvider.flatMap { provider in
      order.first { $0.provider == provider }
    }
    let fading = order.filter { section in
      guard section !== moved,
            let from = previousIndex[ObjectIdentifier(section)],
            let to = order.firstIndex(of: section),
            from != to
      else { return false }
      return true
    }

    if animated {
      animateLayout(fading: fading)
    } else {
      applyLayout()
    }
  }

  // MARK: Layout

  private var currentSectionFrames: [NSRect] { sectionFrames(in: sections) }

  private func sectionFrames(in order: [ProviderSectionView]) -> [NSRect] {
    var y: CGFloat = 0
    return order.map { section in
      let height = section.frame.height
      let frame = NSRect(x: 0, y: y, width: Self.width, height: height)
      y += height + Self.separatorHeight
      return frame
    }
  }

  private func separatorFrames(in order: [ProviderSectionView]) -> [NSRect] {
    let frames = sectionFrames(in: order)
    guard frames.count > 1 else { return [] }
    return (0..<(frames.count - 1)).map { index in
      NSRect(
        x: 6,
        y: frames[index].maxY + (Self.separatorHeight - 1) / 2,
        width: Self.width - 12,
        height: 1
      )
    }
  }

  private func applyLayout() {
    animationGeneration += 1
    for (section, frame) in zip(sections, currentSectionFrames) { section.frame = frame }
    for (hairline, frame) in zip(separators, separatorFrames(in: sections)) { hairline.frame = frame }
    for section in sections { section.alphaValue = 1 }
    frame = NSRect(x: 0, y: 0, width: Self.width, height: totalHeight)
  }

  private func animateLayout(fading: [ProviderSectionView]) {
    animationGeneration += 1
    let generation = animationGeneration

    let frames = currentSectionFrames
    let hairlines = separatorFrames(in: sections)
    for section in sections where !fading.contains(section) {
      section.alphaValue = 1
    }

    NSAnimationContext.runAnimationGroup({ context in
      context.duration = Self.slideDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      for (section, frame) in zip(sections, frames) {
        section.animator().frame = frame
      }
      for (hairline, frame) in zip(separators, hairlines) {
        hairline.animator().frame = frame
      }
      for section in fading {
        section.animator().alphaValue = 0
      }
    }, completionHandler: { [weak self] in
      // The completion handler arrives without an actor context; AppKit calls
      // it on the main thread, so re-establish it before touching the views.
      MainActor.assumeIsolated {
        guard let self, self.animationGeneration == generation else { return }
        NSAnimationContext.runAnimationGroup { context in
          context.duration = Self.fadeDuration
          context.timingFunction = CAMediaTimingFunction(name: .easeOut)
          for section in fading {
            section.animator().alphaValue = 1
          }
        }
      }
    })


    frame = NSRect(x: 0, y: 0, width: Self.width, height: totalHeight)
  }
}
