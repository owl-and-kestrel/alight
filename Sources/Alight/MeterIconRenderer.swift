import AppKit

/// Renders the menu-bar icon as horizontal meters grouped by provider.
///
/// One dark card per provider. On the left, a small square in the provider
/// colour (so a fully white, maxed-out card is still identifiable); on the
/// right, one track per limit
/// window in the provider colour, with a white bar showing usage (or, in
/// Empty mode, what remains). The weekly track sits on top and is thicker;
/// an active scoped weekly limit (Claude's Fable) sits under it as a thinner
/// weekly track, and the ~5h track sits at the bottom. Every card is the same height
/// regardless of how many tracks it holds; a lone track fills its card.
///
/// A dot on each track marks how far through the window the clock is. Where
/// the dot lies on the white bar it is drawn in the provider colour; where it
/// lies on the track it is drawn white; straddling the bar's edge it is
/// two-toned. So a dot sitting on the bar means the clock is behind usage
/// (running hot) and a dot out on the track means usage is behind the clock.
///
/// The card is a fixed dark grey so the meters read on any menu-bar tint.
@MainActor
enum MeterIconRenderer {
  /// Reference height the row metrics are tuned for (a classic 22pt menu bar).
  nonisolated static let standardHeight: CGFloat = 22
  /// Tallest icon we will draw, even on very tall menu bars.
  nonisolated static let maximumHeight: CGFloat = 34

  /// The icon height for this Mac's menu bar: the full bar minus a small
  /// margin on notched displays (the bar is ~32pt there), 22pt otherwise.
  /// Passing a different `menuBarHeight` makes layout deterministic in tests.
  static func iconHeight(menuBarHeight: CGFloat? = nil) -> CGFloat {
    let bar = menuBarHeight ?? currentMenuBarHeight()
    guard bar > standardHeight + 2 else { return standardHeight }
    return min(maximumHeight, (bar - 2).rounded(.down))
  }

  private static func currentMenuBarHeight() -> CGFloat {
    let notch = NSScreen.main?.safeAreaInsets.top ?? 0
    if notch > 0 { return notch }
    return NSApplication.shared.mainMenu?.menuBarHeight ?? NSStatusBar.system.thickness
  }
  /// Width reserved for the optional provider label column.
  /// Width of the swatch column at 22pt; the square inside is as tall as the
  /// card's content, so it is never wider than this.
  static let badgeWidth: CGFloat = 5.0
  static let badgeGap: CGFloat = 1.25
  static let xPad: CGFloat = 0.5
  /// Horizontal inset of the badge and tracks from the card edge.
  static let platePadX: CGFloat = 0.75
  /// Bars a plate can hold: weekly, ~5h, and one scoped weekly limit.
  static let maximumBarsPerRow = 3

  struct MeterBarLayout: Sendable, Equatable {
    let window: UsageWindow
    let rect: NSRect
    let isSlow: Bool
  }

  struct MeterCardLayout: Sendable, Equatable {
    let provider: Provider
    /// The provider's card (swatch plus tracks, with padding).
    let cardRect: NSRect
    /// The square swatch, or `.zero` in bars-only mode.
    let badgeRect: NSRect
    let tracksRect: NSRect
    let bars: [MeterBarLayout]
  }

  /// Vertical rhythm for a given number of provider rows. Everything fits the
  /// 22pt menu-bar height with a little breathing room top and bottom.
  struct RowMetrics: Sendable, Equatable {
    let slowHeight: CGFloat
    let fastHeight: CGFloat
    /// Height of a scoped-limit track (the third track).
    let scopedHeight: CGFloat
    let barGap: CGFloat
    /// Space between cards.
    let rowGap: CGFloat
    /// Vertical padding inside a card, above and below its tracks.
    let platePadY: CGFloat

    /// Every card is at least this tall: room for weekly + ~5h tracks plus
    /// padding. A card with a third (scoped) track grows by `extraBarHeight`.
    var baseHeight: CGFloat { slowHeight + barGap + fastHeight + 2 * platePadY }
    var extraBarHeight: CGFloat { barGap + scopedHeight }

    /// Metrics tuned for a 22pt icon, scaled to `height`. At 22pt three cards
    /// use 21.25pt (3 × 5.5 + Claude's extra 1.75 + 2 × 1.5); taller menu bars
    /// get proportionally taller cards and wider gaps.
    static func forRowCount(_ count: Int, height: CGFloat = standardHeight) -> RowMetrics {
      let base: RowMetrics
      switch count {
      case ...1:
        base = RowMetrics(slowHeight: 5.5, fastHeight: 3.0, scopedHeight: 2.0, barGap: 1.5, rowGap: 0, platePadY: 1.75)
      case 2:
        base = RowMetrics(slowHeight: 4.0, fastHeight: 2.0, scopedHeight: 1.5, barGap: 1.0, rowGap: 1.5, platePadY: 0.75)
      default:
        base = RowMetrics(slowHeight: 2.5, fastHeight: 1.25, scopedHeight: 1.0, barGap: 0.75, rowGap: 1.5, platePadY: 0.5)
      }
      let f = max(1, height / standardHeight)
      // Round to quarter points so edges stay crisp at 2x.
      func q(_ v: CGFloat) -> CGFloat { (v * f * 4).rounded() / 4 }
      return RowMetrics(
        slowHeight: q(base.slowHeight), fastHeight: q(base.fastHeight), scopedHeight: q(base.scopedHeight),
        barGap: q(base.barGap), rowGap: q(base.rowGap), platePadY: q(base.platePadY)
      )
    }
  }

  static func size(for style: MeterIconStyle = AppSettings.meterStyle, height: CGFloat? = nil) -> NSSize {
    let showLabels = style.labelMode != .none
    let h = height ?? iconHeight()
    let labelW = showLabels ? (badgeWidth(for: h) + badgeGap) : 0
    let totalW = xPad + platePadX + labelW + style.width + platePadX + xPad
    return NSSize(width: ceil(totalW), height: h)
  }

  /// The swatch column scales with the icon.
  static func badgeWidth(for height: CGFloat) -> CGFloat {
    (badgeWidth * max(1, height / standardHeight) * 2).rounded() / 2
  }

  /// Groups active usage windows by provider in canonical order ([.codex, .claude, .antigravity]).
  /// Within each group, slow (weekly) windows appear on top before fast (~5h) windows. Dropdown-only
  /// menu rows are excluded.
  static func meterGroups(status: UsageStatus) -> [(provider: Provider, windows: [UsageWindow])] {
    let candidates = status.windows.filter { $0.visualStyle != .menuRow }
    let providerOrder: [Provider] = [.codex, .claude, .antigravity]

    var groups: [(provider: Provider, windows: [UsageWindow])] = []
    for provider in providerOrder {
      let providerWindows = candidates.filter { $0.provider == provider }
      guard !providerWindows.isEmpty else { continue }
      let sorted = providerWindows.sorted { a, b in
        // Weekly tracks first (all-models, then scoped such as Fable), then 5h.
        if a.speed != b.speed {
          return a.speed == .slow
        }
        if (a.scope != nil) != (b.scope != nil) {
          return a.scope == nil
        }
        return a.id < b.id
      }
      groups.append((provider: provider, windows: sorted))
    }
    return groups
  }

  /// Flat list of filtered meter windows in group order.
  static func meterWindows(status: UsageStatus) -> [UsageWindow] {
    meterGroups(status: status).flatMap(\.windows)
  }

  /// Computes the row and bar layouts for each provider.
  static func cardLayouts(
    groups: [(provider: Provider, windows: [UsageWindow])],
    style: MeterIconStyle,
    totalHeight: CGFloat = standardHeight,
    totalWidth: CGFloat
  ) -> [MeterCardLayout] {
    guard !groups.isEmpty else { return [] }

    let count = groups.count
    let metrics = RowMetrics.forRowCount(count, height: totalHeight)
    let showLabels = style.labelMode != .none
    let badgeWidth = badgeWidth(for: totalHeight)

    // Every plate gets the same base height; only a third (scoped) bar adds to it.
    func rowHeight(_ windows: [UsageWindow]) -> CGFloat {
      let bars = min(maximumBarsPerRow, windows.count)
      return metrics.baseHeight + (bars >= 3 ? metrics.extraBarHeight : 0)
    }
    let rowHeights = groups.map { rowHeight($0.windows) }
    let totalSpan = rowHeights.reduce(0, +) + CGFloat(count - 1) * metrics.rowGap
    var cursorY = (totalHeight - totalSpan) / 2

    let rowWidth = totalWidth - 2 * xPad
    let tracksStartX = xPad + platePadX + (showLabels ? badgeWidth + badgeGap : 0)
    let tracksWidth = xPad + rowWidth - platePadX - tracksStartX

    var result: [MeterCardLayout] = []
    // Build bottom-up in AppKit coordinates, then reverse so index 0 is the
    // top row (the first provider).
    for (index, group) in groups.enumerated().reversed() {
      let height = rowHeights[index]
      let rowRect = NSRect(x: xPad, y: cursorY, width: rowWidth, height: height)
      cursorY += height + metrics.rowGap

      let contentY = rowRect.minY + metrics.platePadY
      let contentHeight = height - 2 * metrics.platePadY
      // A square, centred in its column and in the card's base content area
      // (so Claude's taller card gets the same swatch as the others).
      let side = min(badgeWidth, metrics.baseHeight - 2 * metrics.platePadY)
      let badgeRect = showLabels
        ? NSRect(x: xPad + platePadX + (badgeWidth - side) / 2, y: rowRect.midY - side / 2, width: side, height: side)
        : .zero
      let tracksRect = NSRect(x: tracksStartX, y: contentY, width: tracksWidth, height: contentHeight)

      // Tracks stack top-down (weekly, ~5h, scoped) and are centred vertically
      // in the card, so every provider sits on the same-sized card.
      let windows = Array(group.windows.prefix(maximumBarsPerRow))
      func barHeight(_ window: UsageWindow) -> CGFloat {
        // A lone track fills its card, like the mockup's Codex row.
        if windows.count == 1 { return contentHeight }
        if window.scope != nil { return metrics.scopedHeight }
        return window.speed == .slow ? metrics.slowHeight : metrics.fastHeight
      }
      let stackHeight = windows.map(barHeight).reduce(0, +) + CGFloat(max(0, windows.count - 1)) * metrics.barGap
      var barTop = contentY + contentHeight - (contentHeight - stackHeight) / 2
      var bars: [MeterBarLayout] = []
      for window in windows {
        let h = barHeight(window)
        let rect = NSRect(x: tracksStartX, y: barTop - h, width: tracksWidth, height: h)
        bars.append(MeterBarLayout(window: window, rect: rect, isSlow: window.speed == .slow && window.scope == nil))
        barTop -= h + metrics.barGap
      }

      result.append(MeterCardLayout(
        provider: group.provider,
        cardRect: rowRect,
        badgeRect: badgeRect,
        tracksRect: tracksRect,
        bars: bars
      ))
    }

    return result.reversed()
  }

  /// Calculates what portion (0.0 to 1.0) of the period has elapsed.
  static func elapsedFraction(for window: UsageWindow, now: Date) -> CGFloat {
    let duration = max(60, window.limitWindowSeconds)
    let rawRemaining = window.resetAt.timeIntervalSince(now)
    guard duration.isFinite, rawRemaining.isFinite else {
      return 0
    }
    let remaining = min(duration, max(0, rawRemaining))
    let elapsed = duration - remaining
    return CGFloat(min(1.0, max(0.0, elapsed / duration)))
  }

  /// Calculates level fraction (0.0 to 1.0) according to fill mode.
  static func levelFraction(for window: UsageWindow, fillMode: MeterFillMode) -> CGFloat {
    switch fillMode {
    case .fill:
      return CGFloat(min(1.0, max(0.0, window.usedPercent / 100.0)))
    case .empty:
      return CGFloat(min(1.0, max(0.0, window.remainingPercent / 100.0)))
    }
  }

  /// Calculates the horizontal position for the period elapsed indicator tick.
  static func indicatorPosition(
    elapsed: CGFloat,
    barX: CGFloat,
    barWidth: CGFloat,
    fillMode: MeterFillMode,
    direction: MeterDirection
  ) -> CGFloat {
    let clampedElapsed = min(1.0, max(0.0, elapsed))
    switch fillMode {
    case .fill:
      switch direction {
      case .leftToRight:
        return barX + barWidth * clampedElapsed
      case .rightToLeft:
        return barX + barWidth * (1.0 - clampedElapsed)
      }
    case .empty:
      switch direction {
      case .leftToRight:
        return barX + barWidth * (1.0 - clampedElapsed)
      case .rightToLeft:
        return barX + barWidth * clampedElapsed
      }
    }
  }

  /// Computes the fill rectangle given the level fraction, track dimensions, and direction.
  static func fillRect(
    level: CGFloat,
    barX: CGFloat,
    barY: CGFloat,
    barWidth: CGFloat,
    barHeight: CGFloat,
    direction: MeterDirection
  ) -> NSRect {
    let fillW = barWidth * max(0, min(1.0, level))
    switch direction {
    case .leftToRight:
      return NSRect(x: barX, y: barY, width: fillW, height: barHeight)
    case .rightToLeft:
      return NSRect(x: barX + barWidth - fillW, y: barY, width: fillW, height: barHeight)
    }
  }

  /// Base accent color for a provider.
  static func fillColor(for provider: Provider, style: MeterIconStyle) -> NSColor {
    switch provider {
    case .codex:
      return style.codexColor
    case .claude:
      return style.claudeColor
    case .antigravity:
      return style.antigravityColor
    }
  }

  /// Provider accent color for the meter bar.
  static func fillColor(for window: UsageWindow, style: MeterIconStyle) -> NSColor {
    fillColor(for: window.provider, style: style)
  }

  /// Legacy bar geometry helper kept for backwards compatibility.
  static func barGeometry(
    count: Int,
    totalHeight: CGFloat = standardHeight,
    barWidth: CGFloat
  ) -> [(y: CGFloat, height: CGFloat)] {
    guard count > 0 else { return [] }
    let barHeight: CGFloat = count == 1 ? 5.0 : (count == 2 ? 4.0 : 3.0)
    let spacing: CGFloat = count == 1 ? 0 : (count == 2 ? 3.0 : 1.5)
    let totalSpan = CGFloat(count) * barHeight + CGFloat(count - 1) * spacing
    let startY = (totalHeight - totalSpan) / 2
    return (0..<count).map { index in
      let y = startY + CGFloat(count - 1 - index) * (barHeight + spacing)
      return (y: y, height: barHeight)
    }
  }

  // MARK: - Drawing

  /// Fixed dark card so the meters read on any menu-bar tint.
  static let plateColor = NSColor(white: 0.30, alpha: 0.96)

  /// Card corner radius. Elements inside the card use a concentric radius
  /// (`innerRadius`) so their corners stay inside the card's rounded corners.
  private static func cornerRadius(for height: CGFloat) -> CGFloat { 2.0 }
  private static func innerRadius(cardRadius: CGFloat, inset: CGFloat, height: CGFloat) -> CGFloat {
    min(max(0.75, cardRadius - inset), height / 2)
  }
  private static let barColor = NSColor.white
  /// Thin dark edge on the white bar, dot and label so they stay legible on
  /// light provider colours such as Codex teal.
  private static let outlineColor = NSColor(white: 0.1, alpha: 0.7)
  private static let outlineWidth: CGFloat = 0.6
  /// Renders the multi-meter image for the menu bar.
  static func image(
    status: UsageStatus,
    scale: CGFloat = 1,
    style: MeterIconStyle = AppSettings.meterStyle,
    now: Date = Date()
  ) -> NSImage {
    let iconSize = size(for: style)
    let image = NSImage(size: NSSize(width: iconSize.width * scale, height: iconSize.height * scale))

    image.lockFocus()
    if scale != 1 {
      let transform = NSAffineTransform()
      transform.scale(by: scale)
      transform.concat()
    }

    let groups = meterGroups(status: status)
    let showLabels = style.labelMode != .none

    if groups.isEmpty {
      // No data: one empty card so the item keeps its footprint.
      let metrics = RowMetrics.forRowCount(1, height: iconSize.height)
      let badgeWidth = badgeWidth(for: iconSize.height)
      let radius = cornerRadius(for: iconSize.height)
      let plate = NSRect(x: xPad, y: (iconSize.height - metrics.baseHeight) / 2, width: iconSize.width - 2 * xPad, height: metrics.baseHeight)
      plateColor.setFill()
      NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius).fill()
      let tracksStartX = xPad + platePadX + (showLabels ? badgeWidth + badgeGap : 0)
      let placeholder = NSRect(
        x: tracksStartX,
        y: plate.minY + metrics.platePadY,
        width: plate.maxX - platePadX - tracksStartX,
        height: plate.height - 2 * metrics.platePadY
      )
      NSColor(white: 0.5, alpha: 0.6).setFill()
      let placeholderRadius = innerRadius(cardRadius: radius, inset: platePadX, height: placeholder.height)
      NSBezierPath(roundedRect: placeholder, xRadius: placeholderRadius, yRadius: placeholderRadius).fill()
    } else {
      let cards = cardLayouts(
        groups: groups,
        style: style,
        totalHeight: iconSize.height,
        totalWidth: iconSize.width
      )
      let radius = cornerRadius(for: iconSize.height)
      // One dot size for every track: sized from the weekly track of a
      // multi-track card so it neither swamps the thin 5h track nor gets lost
      // on a lone full-height one.
      let metrics = RowMetrics.forRowCount(groups.count, height: iconSize.height)
      let dotDiameter = max(1.5, (metrics.slowHeight * 0.66 * 4).rounded() / 4)

      for card in cards {
        let accent = fillColor(for: card.provider, style: style)

        // 1. Card.
        plateColor.setFill()
        NSBezierPath(roundedRect: card.cardRect, xRadius: radius, yRadius: radius).fill()

        // 2. Swatch: a provider-coloured square.
        if showLabels {
          accent.setFill()
          let swatchRadius = innerRadius(cardRadius: radius, inset: platePadX, height: card.badgeRect.height)
          NSBezierPath(roundedRect: card.badgeRect, xRadius: swatchRadius, yRadius: swatchRadius).fill()
        }

        for bar in card.bars {
          let trackRect = bar.rect
          let trackRadius = innerRadius(cardRadius: radius, inset: platePadX, height: trackRect.height)
          let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: trackRadius, yRadius: trackRadius)

          // 3. Track in the provider colour.
          accent.setFill()
          trackPath.fill()

          // 4. White bar: usage (Fill) or what remains (Empty), inset a hair
          //    so the coloured track still edges it.
          let level = levelFraction(for: bar.window, fillMode: style.fillMode)
          var barPath: NSBezierPath?
          if level > 0 {
            let inset: CGFloat = trackRect.height >= 2.5 ? 0.5 : 0.25
            let full = fillRect(
              level: level,
              barX: trackRect.minX,
              barY: trackRect.minY,
              barWidth: trackRect.width,
              barHeight: trackRect.height,
              direction: style.direction
            )
            let fRect = full.insetBy(dx: 0, dy: inset).insetBy(dx: inset, dy: 0)
            if fRect.width > 0 {
              let barRadius = min(max(0, trackRadius - inset), fRect.height / 2)
              let path = NSBezierPath(roundedRect: fRect, xRadius: barRadius, yRadius: barRadius)
              barColor.setFill()
              path.fill()
              outlineColor.setStroke()
              path.lineWidth = outlineWidth
              path.stroke()
              barPath = path
            }
          }

          // 5. Pace dot: provider colour where it sits on the white bar, white
          //    where it sits on the track; two-toned across the bar's edge.
          let elapsed = elapsedFraction(for: bar.window, now: now)
          let dotX = indicatorPosition(
            elapsed: elapsed,
            barX: trackRect.minX,
            barWidth: trackRect.width,
            fillMode: style.fillMode,
            direction: style.direction
          )
          let dotRadius = dotDiameter / 2
          let clampedX = max(trackRect.minX + dotRadius + 0.25, min(trackRect.maxX - dotRadius - 0.25, dotX))
          let dotPath = NSBezierPath(ovalIn: NSRect(
            x: clampedX - dotRadius,
            y: trackRect.midY - dotRadius,
            width: dotDiameter,
            height: dotDiameter
          ))

          barColor.setFill()
          if let barPath {
            NSGraphicsContext.saveGraphicsState()
            let outside = NSBezierPath(rect: trackRect.insetBy(dx: -2, dy: -2))
            outside.append(barPath)
            outside.windingRule = .evenOdd
            outside.addClip()
            dotPath.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGraphicsContext.saveGraphicsState()
            barPath.addClip()
            accent.setFill()
            dotPath.fill()
            NSGraphicsContext.restoreGraphicsState()
          } else {
            dotPath.fill()
          }
          outlineColor.setStroke()
          dotPath.lineWidth = outlineWidth
          dotPath.stroke()
        }
      }
    }

    image.unlockFocus()
    image.isTemplate = false
    return image
  }
}
