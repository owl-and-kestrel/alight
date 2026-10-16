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
