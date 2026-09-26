import AppKit

// MARK: - Provider Header Row View

@MainActor
final class ProviderHeaderRowView: NSView {
  private let swatchColor: NSColor
  private let providerName: String
  private let statusText: String
  private let statusColor: NSColor

  override var isFlipped: Bool { true }

  init(
    provider: Provider,
    color: NSColor,
    result: ProviderResult?
  ) {
    self.swatchColor = color
    self.providerName = provider.displayName

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

    super.init(frame: NSRect(x: 0, y: 0, width: 286, height: 26))

    // Provider name label
    let titleLabel = NSTextField(labelWithString: providerName)
    titleLabel.font = .systemFont(ofSize: 12.5, weight: .bold)
    titleLabel.textColor = .labelColor
    titleLabel.frame = NSRect(x: 34, y: 5, width: 140, height: 16)
    addSubview(titleLabel)

    // Status / cache label
    let statusLabel = NSTextField(labelWithString: statusText)
    statusLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
    statusLabel.textColor = statusColor
    statusLabel.alignment = .right
    statusLabel.frame = NSRect(x: 174, y: 6, width: 98, height: 15)
    addSubview(statusLabel)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    // Swatch: rounded square with subtle border
    let swatchRect = NSRect(x: 14, y: 6, width: 13, height: 13)
    let swatchPath = NSBezierPath(roundedRect: swatchRect, xRadius: 3.0, yRadius: 3.0)
    swatchColor.setFill()
    swatchPath.fill()

    NSColor(white: 0.0, alpha: 0.15).setStroke()
    swatchPath.lineWidth = 0.5
    swatchPath.stroke()
  }
}

// MARK: - Usage Window Row View

@MainActor
final class UsageWindowRowView: NSView {
  private let usageWindow: UsageWindow
  private let accentColor: NSColor
  private let fillMode: MeterFillMode
  private let now: Date

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

    // 3. Reset countdown on bottom right
    let countdownLabel = NSTextField(labelWithString: "resets in \(window.resetCountdown(now: now))")
    countdownLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
    countdownLabel.textColor = .secondaryLabelColor
    countdownLabel.alignment = .right
    countdownLabel.frame = NSRect(x: 160, y: 20, width: 112, height: 14)
    addSubview(countdownLabel)
  }

  required init?(coder: NSCoder) {
    nil
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
