import AppKit

/// Renders the menu-bar dial as a dark circle with a dotted pressure scale,
/// broad-limit hands, and a small open reset clock in the unused bottom arc. The
/// pressure hands remain dominant; the reset clock is a secondary glanceable
/// readout of where each active broad window sits in its cycle.
///
/// The canvas is square so the dial never crops against the menu bar.
///
/// Deconfliction:
///   • provider  -> hand color (Codex teal, Claude coral)
///   • window    -> radius + depth: weekly is long; fast (~5h) is short.
///   • scope     -> marker: scoped model limits such as Claude Fable draw as
///                  four-point stars on the outer edge, not as extra hands.
/// The reset clock reuses provider color, with weekly hands on a seven-tick
/// inner track and ~5h hands on a five-tick outer track. Each hand rotates
/// clockwise through a full cycle and returns to 12 at reset.
enum GaugeIconRenderer {
  static let size = NSSize(width: 22, height: 22)
  private static let circleRadius: CGFloat = 10.5
  private static let dotCount = 16
  private static let dialStart: CGFloat = 230
  private static let dialSweep: CGFloat = -280
  // The reset hands span roughly half the full dial's diameter: large enough
  // to read at the actual 22pt menu-bar size, while remaining secondary.
  private static let resetDialCenterYOffset: CGFloat = -5.60
  private static let resetWeeklyTrackRadius: CGFloat = 2.55
  private static let resetFastTrackRadius: CGFloat = 4.05
  private static let resetWeeklyTickLength: CGFloat = 0.60
  private static let resetFastTickLength: CGFloat = 0.75
  private static let resetWeeklyHandLength: CGFloat = 2.65
  private static let resetFastHandLength: CGFloat = 3.75
  private static let resetWeeklyHandWidth: CGFloat = 0.95
  private static let resetFastHandWidth: CGFloat = 1.02
  /// Consumption fraction beyond which the scale dots turn red.
  private static let redlineFraction: CGFloat = 0.78

  @MainActor
  static func image(
    status: UsageStatus,
    scale: CGFloat = 1,
    style: GaugeIconStyle = AppSettings.iconStyle,
    now: Date = Date()
  ) -> NSImage {
    let center = NSPoint(x: size.width / 2, y: size.height / 2)
    let image = NSImage(size: NSSize(width: size.width * scale, height: size.height * scale))

    image.lockFocus()
    if scale != 1 {
      let transform = NSAffineTransform()
      transform.scale(by: scale)
      transform.concat()
    }
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()

    drawFace(center: center)
    drawScale(center: center, style: style)

    let resetWindows = resetDialWindows(status: status, now: now)
    let resetCenter = NSPoint(x: center.x, y: center.y + resetDialCenterYOffset)
    // The complete time display is a background layer. Quota hands and scoped
    // markers draw over it whenever the two systems cross.
    drawResetGraduations(center: resetCenter, windows: resetWindows)
    drawResetHands(center: resetCenter, windows: resetWindows, style: style, now: now)

    // Draw long (slow) lines first, then short (fast) lines on top, so a short
    // outer line is never hidden under a long line when their angles align.
    // Within each band, the most-constrained (lowest pressure) draws last.
    let hands = status.windows.filter { $0.visualStyle == .hand }.sorted { a, b in
      if a.speed != b.speed { return a.speed == .slow }
      return a.pressurePercent > b.pressurePercent
    }
    for window in hands {
      drawHand(center: center, window: window, style: style)
    }

    // Scoped limits are sparse overlays. Draw them after hands so a present
    // model-specific limit is visible without pretending it is another window
    // hand in the two-band system.
    let markers = status.windows.filter { $0.visualStyle == .outerStar }.sorted {
      $0.pressurePercent > $1.pressurePercent
    }
    for window in markers {
      drawOuterStar(center: center, window: window, style: style)
    }

    drawHub(center: center, style: style)

    image.unlockFocus()
    image.isTemplate = false
    return image
  }

  // MARK: - Face & scale

  private static func drawFace(center: NSPoint) {
    let rect = NSRect(x: center.x - circleRadius, y: center.y - circleRadius, width: circleRadius * 2, height: circleRadius * 2)
    NSColor(calibratedWhite: 0.09, alpha: 0.96).setFill()
    NSBezierPath(ovalIn: rect).fill()
  }

  private static func drawScale(center: NSPoint, style: GaugeIconStyle) {
    // Small white dots form the scale up to the redline — kept subtle so the
    // hands dominate.
    let dotR = style.scaleDotSize
    NSColor(calibratedWhite: 0.90, alpha: 0.8).setFill()
    for index in 0..<dotCount {
      let fraction = CGFloat(index) / CGFloat(dotCount - 1)
      if fraction >= redlineFraction { continue }
      let angle = (dialStart + dialSweep * fraction) * .pi / 180
      let point = NSPoint(x: center.x + cos(angle) * style.scaleRadius, y: center.y + sin(angle) * style.scaleRadius)
      NSBezierPath(ovalIn: NSRect(x: point.x - dotR, y: point.y - dotR, width: dotR * 2, height: dotR * 2)).fill()
    }

    // The redline is a solid bright-red arc over the hot end, not dots.
    let redStart = dialStart + dialSweep * redlineFraction
    let redEnd = dialStart + dialSweep
    style.redlineColor.setStroke()
    let arc = NSBezierPath()
    arc.lineWidth = style.redlineWidth
    arc.lineCapStyle = .round
    arc.appendArc(withCenter: center, radius: style.scaleRadius, startAngle: redStart, endAngle: redEnd, clockwise: true)
    arc.stroke()
  }

  // MARK: - Hands

  // The circle face ends at `circleRadius` = 10.5.
  // The two window kinds occupy different radial bands so they never swallow
  // each other when their angles align.
  private static func drawHand(center: NSPoint, window: UsageWindow, style: GaugeIconStyle) {
    let radians = angle(for: window) * .pi / 180
    let dx = cos(radians)
    let dy = sin(radians)
    let nx = -dy
    let ny = dx

    // (r) = distance along the hand's angle, (t) = tangential offset.
    func point(_ r: CGFloat, _ t: CGFloat = 0) -> NSPoint {
      NSPoint(x: center.x + dx * r + nx * t, y: center.y + dy * r + ny * t)
    }

    let line = NSBezierPath()
    let colorWidth: CGFloat
    switch window.speed {
    case .slow:
      // Long window (weekly): a long line from a short tail through the hub out
      // past the tick marks.
      line.move(to: point(style.weeklyHandRadius - style.weeklyHandLength))
      line.line(to: point(style.weeklyHandRadius))
      colorWidth = style.weeklyHandWidth
    case .fast:
      // Short window (5h): a short bold line in the outer band, from the edge
      // inward past the tick marks — an emphasized tick.
      line.move(to: point(style.fastHandRadius))
      line.line(to: point(style.fastHandRadius - style.fastHandLength))
      colorWidth = style.fastHandWidth
    }
    line.lineCapStyle = .round

    // Thin dark edge under the bright color line for separation on overlaps.
    NSColor.black.setStroke()
    line.lineWidth = colorWidth + 0.8
    line.stroke()
    providerColor(window.provider, style: style).setStroke()
    line.lineWidth = colorWidth
    line.stroke()
  }

  private static func drawOuterStar(center: NSPoint, window: UsageWindow, style: GaugeIconStyle) {
    let radians = angle(for: window) * .pi / 180
    let dx = cos(radians)
    let dy = sin(radians)
    let nx = -dy
    let ny = dx
    let outer = style.fableStarSize
    let inner = style.fableStarSize * 0.35
    let starCenter = NSPoint(
      x: center.x + dx * style.fableStarRadius,
      y: center.y + dy * style.fableStarRadius
    )

    // Four points: outward/inward along the radial axis, and two tangential
    // points. Alternating inner vertices keep it recognizably star-shaped at
    // 22px rather than collapsing into a plain diamond.
    let vertices: [(CGFloat, CGFloat)] = [
      (outer, 0),
      (inner, inner),
      (0, outer),
      (-inner, inner),
      (-outer, 0),
      (-inner, -inner),
      (0, -outer),
      (inner, -inner)
    ]

    func point(radial: CGFloat, tangent: CGFloat) -> NSPoint {
      NSPoint(
        x: starCenter.x + dx * radial + nx * tangent,
        y: starCenter.y + dy * radial + ny * tangent
      )
    }

    let star = NSBezierPath()
    let first = vertices[0]
    star.move(to: point(radial: first.0, tangent: first.1))
    for vertex in vertices.dropFirst() {
      star.line(to: point(radial: vertex.0, tangent: vertex.1))
    }
    star.close()

    NSColor.black.setStroke()
    star.lineJoinStyle = .round
    star.lineWidth = 0.45
    providerColor(window.provider, style: style).setFill()
    star.fill()
    star.stroke()
  }

  private static func drawHub(center: NSPoint, style: GaugeIconStyle) {
    let r = style.hubSize
    guard r > 0 else {
      return
    }
    let cap = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    NSColor.black.setFill()
    cap.fill()
  }

  // MARK: - Reset clock

  /// The reset clock occupies the 80-degree gap beneath the pressure scale.
  /// It intentionally excludes scoped markers: those retain their distinct
  /// star grammar on the main dial and their exact reset in the menu.
  private static func drawResetHands(
    center: NSPoint,
    windows: [UsageWindow],
    style: GaugeIconStyle,
    now: Date
  ) {
    guard !windows.isEmpty else {
      return
    }

    // The hands sit directly on the main dial face. Draw all dark edges first
    // and all provider colors second so a later outline cannot erase a
    // neighboring provider in aligned resets.
    for window in windows {
      drawResetHand(center: center, window: window, style: style, now: now, outlineOnly: true)
    }
    for window in windows {
      drawResetHand(center: center, window: window, style: style, now: now, outlineOnly: false)
    }

    let pinRadius: CGFloat = 0.34
    NSColor(calibratedWhite: 0.96, alpha: 0.92).setFill()
    NSBezierPath(ovalIn: NSRect(
      x: center.x - pinRadius,
      y: center.y - pinRadius,
      width: pinRadius * 2,
      height: pinRadius * 2
    )).fill()
  }

  private static func drawResetGraduations(center: NSPoint, windows: [UsageWindow]) {
    let speeds = Set(windows.map(\.speed))
    let tracks: [(speed: WindowSpeed, count: Int, radius: CGFloat, length: CGFloat, width: CGFloat, alpha: CGFloat)] = [
      (.slow, 7, resetWeeklyTrackRadius, resetWeeklyTickLength, 0.70, 0.64),
      (.fast, 5, resetFastTrackRadius, resetFastTickLength, 0.75, 0.70)
    ]

    for track in tracks where speeds.contains(track.speed) {
      NSColor(calibratedWhite: 0.92, alpha: track.alpha).setStroke()
      for angle in resetGraduationAngles(count: track.count) {
        let radians = angle * .pi / 180
        let dx = cos(radians)
        let dy = sin(radians)
        let innerRadius = track.radius - track.length / 2
        let outerRadius = track.radius + track.length / 2
        let tick = NSBezierPath()
        tick.move(to: NSPoint(
          x: center.x + dx * innerRadius,
          y: center.y + dy * innerRadius
        ))
        tick.line(to: NSPoint(
          x: center.x + dx * outerRadius,
          y: center.y + dy * outerRadius
        ))
        tick.lineWidth = track.width
        tick.lineCapStyle = .round
        tick.stroke()
      }
    }
  }

  private static func drawResetHand(
    center: NSPoint,
    window: UsageWindow,
    style: GaugeIconStyle,
    now: Date,
    outlineOnly: Bool
  ) {
    let radians = resetAngle(for: window, now: now) * .pi / 180
    let length = window.speed == .slow ? resetWeeklyHandLength : resetFastHandLength
    let colorWidth = window.speed == .slow ? resetWeeklyHandWidth : resetFastHandWidth
    let dx = cos(radians)
    let dy = sin(radians)
    let nx = -dy
    let ny = dx
    // A fractional provider lane keeps coincident Codex/Claude/Antigravity resets
    // visible as distinct lines instead of letting the later draw erase one source.
    let providerOffset: CGFloat
    switch window.provider {
    case .codex:
      providerOffset = -0.30
    case .antigravity:
      providerOffset = 0.0
    case .claude:
      providerOffset = 0.30
    }
    let origin = NSPoint(
      x: center.x + nx * providerOffset,
      y: center.y + ny * providerOffset
    )
    let tip = NSPoint(
      x: origin.x + dx * length,
      y: origin.y + dy * length
    )
    let hand = NSBezierPath()
    hand.move(to: origin)
    hand.line(to: tip)
    hand.lineCapStyle = .round

    if outlineOnly {
      NSColor.black.setStroke()
      hand.lineWidth = colorWidth + 0.70
    } else {
      providerColor(window.provider, style: style).setStroke()
      hand.lineWidth = colorWidth
    }
    hand.stroke()
  }

  static func resetDialWindows(status: UsageStatus, now: Date) -> [UsageWindow] {
    status.windows
      .filter {
        $0.visualStyle == .hand
          && $0.scope == nil
          && $0.resetAt > now
      }
      .sorted { a, b in
        // Inner weekly hands establish the background; outer fast hands remain
        // visible on top. Within a track, the sooner reset draws last.
        if a.speed != b.speed {
          return a.speed == .slow
        }
        if a.resetAt != b.resetAt {
          return a.resetAt > b.resetAt
        }
        return a.provider.rawValue < b.provider.rawValue
      }
  }

  static func resetGraduationAngles(count: Int) -> [CGFloat] {
    guard count > 0 else {
      return []
    }
    return (0..<count).map { index in
      90 - CGFloat(index) * 360 / CGFloat(count)
    }
  }

  static func resetAngle(for window: UsageWindow, now: Date) -> CGFloat {
    let duration = max(60, window.limitWindowSeconds)
    let rawRemaining = window.resetAt.timeIntervalSince(now)
    guard duration.isFinite, rawRemaining.isFinite else {
      return 90
    }
    let remaining = min(duration, max(0, rawRemaining))
    let elapsedFraction = 1 - remaining / duration
    return 90 - CGFloat(elapsedFraction) * 360
  }

  // MARK: - Colors

  /// Provider accent for the hands and the dropdown swatch. Tuned to read as
  /// vivid teal / coral on the dark face, and distinct from each other.
  static func providerColor(_ provider: Provider, style: GaugeIconStyle = AppSettings.iconStyle) -> NSColor {
    switch provider {
    case .codex:
      style.codexColor
    case .claude:
      style.claudeColor
    case .antigravity:
      style.antigravityColor
    }
  }

  // MARK: - Pace-relative angle

  static func angle(for window: UsageWindow?) -> CGFloat {
    guard let window else {
      return 90
    }
    return angle(
      usedPercent: window.usedPercent,
      expectedRemainingPercent: window.expectedRemainingPercent
    )
  }

  static func angle(usedPercent: Double, expectedRemainingPercent: Double) -> CGFloat {
    let position = dialPosition(
      usedPercent: usedPercent,
      expectedRemainingPercent: expectedRemainingPercent
    )
    return dialStart + CGFloat(position / 100) * dialSweep
  }

  static func dialPosition(usedPercent: Double, expectedRemainingPercent: Double) -> Double {
    let used = min(100, max(0, usedPercent))
    let expectedUsed = min(100, max(0, 100 - expectedRemainingPercent))

    // The dial is pace-relative: 0% consumed is the left endpoint, exactly
    // on-track is the center, and fully consumed is the right endpoint.
    if used <= 0 {
      return 0
    }
    if used >= 100 {
      return 100
    }
    if expectedUsed <= 0 {
      return 50 + used / 100 * 50
    }
    if expectedUsed >= 100 {
      return used / 100 * 50
    }
    if used <= expectedUsed {
      return used / expectedUsed * 50
    }
    return 50 + (used - expectedUsed) / (100 - expectedUsed) * 50
  }
}

extension PressureBand {
  var nsColor: NSColor {
    switch self {
    case .high:
      NSColor.systemBlue
    case .good:
      NSColor.systemGreen
    case .low:
      NSColor.systemRed
    case .unknown:
      NSColor.systemGray
    }
  }
}
