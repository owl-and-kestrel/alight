import AppKit

/// Developer-only previews. `--render` produces a labeled QA sheet;
/// `--render-plate` produces the square, text-free public product plate. Neither
/// mode touches the menu bar or any live credentials.
@MainActor
enum RenderHarness {
  static func run(outputPath: String) {
    let scenarios: [(String, UsageStatus)] = [
      ("typical", sample(codexFast: nil, codexSlow: 55, claudeFast: 74, claudeSlow: 18, antigravityFast: 35, antigravitySlow: 60)),
      ("codex only", sample(codexFast: nil, codexSlow: 80, claudeFast: nil, claudeSlow: nil)),
      ("claude only", sample(codexFast: nil, codexSlow: nil, claudeFast: 60, claudeSlow: 30)),
      ("antigravity only", sample(codexFast: nil, codexSlow: nil, claudeFast: nil, claudeSlow: nil, antigravityFast: 72, antigravitySlow: 42)),
      ("fable scoped", sample(codexFast: nil, codexSlow: 45, claudeFast: 0, claudeSlow: 44, claudeFable: 78, antigravityFast: 20, antigravitySlow: 50)),
      ("aligned resets", sample(codexFast: nil, codexSlow: 34, claudeFast: 48, claudeSlow: 28, antigravityFast: 55, antigravitySlow: 38, alignedResets: true)),
      ("pegged", sample(codexFast: nil, codexSlow: 100, claudeFast: 50, claudeSlow: 0, antigravityFast: 0, antigravitySlow: 100))
    ]

    let previewScale: CGFloat = 12
    let displayScale: CGFloat = 2
    let tile = NSSize(
      width: GaugeIconRenderer.size.width * previewScale,
      height: GaugeIconRenderer.size.height * previewScale
    )
    let labelStrip: CGFloat = 22
    let padding: CGFloat = 16
    let backgrounds: [(String, NSColor, NSAppearance?)] = [
      ("light", NSColor(white: 0.95, alpha: 1), NSAppearance(named: .aqua)),
      ("dark", NSColor(white: 0.12, alpha: 1), NSAppearance(named: .darkAqua))
    ]

    let cols = scenarios.count
    let rows = backgrounds.count
    let sheet = NSImage(size: NSSize(
      width: padding + CGFloat(cols) * (tile.width + padding),
      height: padding + CGFloat(rows) * (tile.height + labelStrip + padding)
    ))

    sheet.lockFocus()
    // Render at a Retina-sized 2x backing resolution, then use a crisp
    // nearest-neighbor upscale so the QA sheet exposes real display pixels.
    NSGraphicsContext.current?.imageInterpolation = .none
    NSColor(white: 0.3, alpha: 1).setFill()
    NSRect(origin: .zero, size: sheet.size).fill()

    for (rowIndex, background) in backgrounds.enumerated() {
      let appearance = background.2 ?? NSApp.effectiveAppearance
      for (colIndex, scenario) in scenarios.enumerated() {
        let originX = padding + CGFloat(colIndex) * (tile.width + padding)
        let originY = padding + CGFloat(rowIndex) * (tile.height + labelStrip + padding)

        let cell = NSRect(x: originX, y: originY + labelStrip, width: tile.width, height: tile.height)
        background.1.setFill()
        NSBezierPath(roundedRect: cell, xRadius: 10, yRadius: 10).fill()

        var icon = NSImage()
        appearance.performAsCurrentDrawingAppearance {
          icon = GaugeIconRenderer.image(
            status: scenario.1,
            scale: displayScale,
            now: scenario.1.generatedAt
          )
        }
        icon.draw(in: cell, from: .zero, operation: .sourceOver, fraction: 1)

        let label = "\(scenario.0) · \(background.0)"
        let attrs: [NSAttributedString.Key: Any] = [
          .foregroundColor: NSColor.white,
          .font: NSFont.systemFont(ofSize: 12)
        ]
        label.draw(at: NSPoint(x: originX, y: originY), withAttributes: attrs)
      }
    }
    sheet.unlockFocus()

    writePNG(sheet, outputPath: outputPath)
  }

  static func runMeters(outputPath: String) {
    let typicalStatus = sample(
      codexFast: nil,
      codexSlow: 55,
      claudeFast: 74,
      claudeSlow: 18,
      claudeFable: 78,
      antigravityFast: 35,
      antigravitySlow: 60
    )
    let peggedStatus = sample(
      codexFast: nil,
      codexSlow: 100,
      claudeFast: 50,
      claudeSlow: 0,
      antigravityFast: 0,
      antigravitySlow: 100
    )
    // Everything running hot: fill past every pace tick.
    let hotStatus = sample(
      codexFast: nil,
      codexSlow: 90,
      claudeFast: 95,
      claudeSlow: 70,
      antigravityFast: 60,
      antigravitySlow: 85
    )
    let codexOnlyStatus = sample(codexFast: nil, codexSlow: 80, claudeFast: nil, claudeSlow: nil)
    let claudeOnlyStatus = sample(codexFast: nil, codexSlow: nil, claudeFast: 60, claudeSlow: 30)
    let twoProviderStatus = sample(codexFast: nil, codexSlow: 40, claudeFast: 85, claudeSlow: 20)

    let meterScenarios: [(String, UsageStatus, MeterFillMode, MeterDirection, MeterLabelMode)] = [
      ("typical", typicalStatus, .fill, .leftToRight, .swatch),
      ("typical · bars only", typicalStatus, .fill, .leftToRight, .none),
      ("typical · empty RTL", typicalStatus, .empty, .rightToLeft, .swatch),
      ("hot", hotStatus, .fill, .leftToRight, .swatch),
      ("hot · empty LTR", hotStatus, .empty, .leftToRight, .swatch),
      ("pegged", peggedStatus, .fill, .leftToRight, .swatch),
      ("two providers", twoProviderStatus, .fill, .leftToRight, .swatch),
      ("claude only", claudeOnlyStatus, .fill, .leftToRight, .swatch),
      ("codex only", codexOnlyStatus, .fill, .leftToRight, .swatch)
    ]

    let previewScale: CGFloat = 8
    let displayScale: CGFloat = 2
    let meterWidth: CGFloat = 36
    let sampleStyle = MeterIconStyle(
      width: meterWidth,
      fillMode: .fill,
      direction: .leftToRight,
      labelMode: .swatch,
      codexColor: AppSettings.codexColor.nsColor,
      claudeColor: AppSettings.claudeColor.nsColor,
      antigravityColor: AppSettings.antigravityColor.nsColor
    )
    let maxIconWidth = MeterIconRenderer.size(for: sampleStyle).width
    let iconHeight = MeterIconRenderer.size(for: sampleStyle).height
    let tile = NSSize(
      width: maxIconWidth * previewScale + 16,
      height: iconHeight * previewScale
    )
    let labelStrip: CGFloat = 22
    let padding: CGFloat = 16
    let backgrounds: [(String, NSColor, NSAppearance?)] = [
      ("light", NSColor(white: 0.95, alpha: 1), NSAppearance(named: .aqua)),
      ("blue tint", NSColor(srgbRed: 0.42, green: 0.62, blue: 0.88, alpha: 1), NSAppearance(named: .aqua)),
      ("dark", NSColor(white: 0.12, alpha: 1), NSAppearance(named: .darkAqua))
    ]

    let cols = meterScenarios.count
    let rows = backgrounds.count
    // A strip of retina-pixel (2x) renders at 1:1 sits under the magnified
    // sheet, so the PNG also shows roughly what the menu bar shows.
    let actualStripHeight = iconHeight * displayScale + 2 * padding
    let sheet = NSImage(size: NSSize(
      width: padding + CGFloat(cols) * (tile.width + padding),
      height: padding + CGFloat(rows) * (tile.height + labelStrip + padding) + actualStripHeight * CGFloat(backgrounds.count)
    ))

    sheet.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .none
    NSColor(white: 0.3, alpha: 1).setFill()
    NSRect(origin: .zero, size: sheet.size).fill()

    for (rowIndex, background) in backgrounds.enumerated() {
      let appearance = background.2 ?? NSApp.effectiveAppearance
      let stripY = CGFloat(rowIndex) * actualStripHeight
      let strip = NSRect(x: 0, y: stripY, width: sheet.size.width, height: actualStripHeight)
      background.1.setFill()
      strip.fill()
      var x = padding
      for scenario in meterScenarios {
        let style = MeterIconStyle(
          width: meterWidth,
          fillMode: scenario.2,
          direction: scenario.3,
          labelMode: scenario.4,
          codexColor: AppSettings.codexColor.nsColor,
          claudeColor: AppSettings.claudeColor.nsColor,
          antigravityColor: AppSettings.antigravityColor.nsColor
        )
        var icon = NSImage()
        appearance.performAsCurrentDrawingAppearance {
          icon = MeterIconRenderer.image(status: scenario.1, scale: displayScale, style: style, now: scenario.1.generatedAt)
        }
        icon.draw(
          in: NSRect(x: x, y: stripY + padding, width: icon.size.width, height: icon.size.height),
          from: .zero,
          operation: .sourceOver,
          fraction: 1
        )
        x += icon.size.width + padding * 2
      }
    }

    for (rowIndex, background) in backgrounds.enumerated() {
      let appearance = background.2 ?? NSApp.effectiveAppearance
      for (colIndex, scenario) in meterScenarios.enumerated() {
        let originX = padding + CGFloat(colIndex) * (tile.width + padding)
        let originY = actualStripHeight * CGFloat(backgrounds.count) + padding + CGFloat(rowIndex) * (tile.height + labelStrip + padding)

        let cell = NSRect(x: originX, y: originY + labelStrip, width: tile.width, height: tile.height)
        background.1.setFill()
        NSBezierPath(roundedRect: cell, xRadius: 10, yRadius: 10).fill()

        let style = MeterIconStyle(
          width: meterWidth,
          fillMode: scenario.2,
          direction: scenario.3,
          labelMode: scenario.4,
          codexColor: AppSettings.codexColor.nsColor,
          claudeColor: AppSettings.claudeColor.nsColor,
          antigravityColor: AppSettings.antigravityColor.nsColor
        )

        var icon = NSImage()
        appearance.performAsCurrentDrawingAppearance {
          icon = MeterIconRenderer.image(
            status: scenario.1,
            scale: displayScale,
            style: style,
            now: scenario.1.generatedAt
          )
        }
        let renderWidth = icon.size.width * previewScale / displayScale
        let renderHeight = icon.size.height * previewScale / displayScale
        let iconCell = NSRect(
          x: originX + (tile.width - renderWidth) / 2,
          y: originY + labelStrip + (tile.height - renderHeight) / 2,
          width: renderWidth,
          height: renderHeight
        )
        icon.draw(in: iconCell, from: .zero, operation: .sourceOver, fraction: 1)

        let label = "\(scenario.0) · \(background.0)"
        let attrs: [NSAttributedString.Key: Any] = [
          .foregroundColor: NSColor.white,
          .font: NSFont.systemFont(ofSize: 10)
        ]
        label.draw(at: NSPoint(x: originX, y: originY), withAttributes: attrs)
      }
    }
    sheet.unlockFocus()

    writePNG(sheet, outputPath: outputPath)
  }

  static func runPlate(outputPath: String) {
    let canvasSize = NSSize(width: 1024, height: 1024)
    let iconScale: CGFloat = 40
    let iconSize = NSSize(
      width: GaugeIconRenderer.size.width * iconScale,
      height: GaugeIconRenderer.size.height * iconScale
    )
    let plate = NSImage(size: canvasSize)
    let status = sample(codexFast: 28, codexSlow: 55, claudeFast: 74, claudeSlow: 18)

    plate.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .none
    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    NSRect(origin: .zero, size: canvasSize).fill()

    var icon = NSImage()
    NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
      icon = GaugeIconRenderer.image(status: status, scale: iconScale, now: status.generatedAt)
    }
    icon.draw(
      in: NSRect(
        x: (canvasSize.width - iconSize.width) / 2,
        y: (canvasSize.height - iconSize.height) / 2,
        width: iconSize.width,
        height: iconSize.height
      ),
      from: .zero,
      operation: .sourceOver,
      fraction: 1
    )
    plate.unlockFocus()

    writePNG(plate, outputPath: outputPath)
  }

  private static func writePNG(_ image: NSImage, outputPath: String) {
    guard
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else {
      FileHandle.standardError.write(Data("render failed\n".utf8))
      exit(1)
    }
    do {
      try png.write(to: URL(fileURLWithPath: outputPath))
      print("wrote \(outputPath)")
    } catch {
      FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
      exit(1)
    }
  }

  private static func sample(
    codexFast: Double?,
    codexSlow: Double?,
    claudeFast: Double?,
    claudeSlow: Double?,
    claudeFable: Double? = nil,
    antigravityFast: Double? = nil,
    antigravitySlow: Double? = nil,
    alignedResets: Bool = false
  ) -> UsageStatus {
    let now = Date()
    func win(
      _ provider: Provider,
      _ speed: WindowSpeed,
      _ used: Double?,
      _ duration: TimeInterval,
      _ elapsedFraction: Double,
      scope: UsageScope? = nil,
      visualStyle: UsageVisualStyle = .hand
    ) -> UsageWindow? {
      guard let used else { return nil }
      // Place the reset so that `elapsedFraction` of the window has passed.
      let resetAt = now.addingTimeInterval(duration * (1 - elapsedFraction))
      return PressureMath.window(
        provider: provider,
        speed: speed,
        usedPercent: used,
        resetAt: resetAt,
        limitWindowSeconds: duration,
        now: now,
        scope: scope,
        visualStyle: visualStyle
      )
    }
    let codexFastPhase = alignedResets ? 0.5 : 0.35
    let codexSlowPhase = alignedResets ? 0.5 : 0.62
    let claudeFastPhase = alignedResets ? 0.5 : 0.78
    let claudeSlowPhase = alignedResets ? 0.5 : 0.45
    let antigravityFastPhase = alignedResets ? 0.5 : 0.22
    let antigravitySlowPhase = alignedResets ? 0.5 : 0.55
    let codexWindows = [
      win(.codex, .fast, codexFast, 5 * 3600, codexFastPhase),
      win(.codex, .slow, codexSlow, 7 * 24 * 3600, codexSlowPhase)
    ].compactMap { $0 }
    let claudeWindows = [
      win(.claude, .fast, claudeFast, 5 * 3600, claudeFastPhase),
      win(.claude, .slow, claudeSlow, 7 * 24 * 3600, claudeSlowPhase),
      win(.claude, .slow, claudeFable, 7 * 24 * 3600, 0.5, scope: .fable, visualStyle: .outerStar)
    ].compactMap { $0 }
    let antigravityWindows = [
      win(.antigravity, .fast, antigravityFast, 5 * 3600, antigravityFastPhase),
      win(.antigravity, .slow, antigravitySlow, 7 * 24 * 3600, antigravitySlowPhase)
    ].compactMap { $0 }
    return UsageStatus(generatedAt: now, results: [
      ProviderResult(provider: .codex, ok: !codexWindows.isEmpty, source: "sample", error: codexWindows.isEmpty ? "sample" : nil, windows: codexWindows),
      ProviderResult(provider: .claude, ok: !claudeWindows.isEmpty, source: "sample", error: claudeWindows.isEmpty ? "sample" : nil, windows: claudeWindows),
      ProviderResult(provider: .antigravity, ok: !antigravityWindows.isEmpty, source: "sample", error: antigravityWindows.isEmpty ? "sample" : nil, windows: antigravityWindows)
    ])
  }
}
