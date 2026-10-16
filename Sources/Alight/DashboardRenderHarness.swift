import AppKit
import SwiftUI

/// `Alight --render-dashboard out.png`: the popover's cards over thirty hours
/// of synthetic history, light and dark side by side, for tuning the layout
/// and charts without live accounts.
@MainActor
enum DashboardRenderHarness {
  static func run(outputPath: String) {
    let now = Date()
    let (status, history) = sample(now: now)
    // The defaults, with the optional elements switched on.
    var layout = DashboardLayout.defaultLayout()
    for card in layout.cards.indices {
      for element in layout.cards[card].elements.indices where layout.cards[card].elements[element].kind == .chart {
        layout.cards[card].elements[element].enabled = true
      }
    }
    layout.cards[1].elements[3].enabled = true
    layout.cards[2].elements[0].valueStyle = .used
    layout.cards[2].elements[1].valueStyle = .used
    layout.cards[2].elements[1].range = .sixHours
    layout.cards[2].elements[2].enabled = false

    // Exercises the bundled core from the app bundle: Fieldbook pace, then
    // Vane's menu-bar selection.
    let paced = QuotaProjection.paced(status, now: now)
    let shown = MenuBarRelevance.select(status: paced, layout: layout)
    print("render-dashboard: menu bar shows \(shown.windows.map(\.id).sorted()) of \(paced.windows.count)")

    let actions = DashboardActions(color: { provider in
      Color(nsColor: GaugeIconRenderer.providerColor(provider, style: AppSettings.iconStyle))
    })
    let size = NSSize(width: DashboardView.width, height: 1)
    let customize = CardCustomizeView(
      card: .constant(layout.cards[1]),
      availableWindows: status.result(for: .claude)?.windows.sorted(by: DashboardCard.displayOrder) ?? [],
      color: actions.color(.claude),
      result: status.result(for: .claude),
      history: history,
      now: now,
      onDone: {},
      onRemove: {}
    )
    let elementPage = CardCustomizeView(
      card: .constant(layout.cards[1]),
      availableWindows: status.result(for: .claude)?.windows.sorted(by: DashboardCard.displayOrder) ?? [],
      color: actions.color(.claude),
      result: status.result(for: .claude),
      history: history,
      now: now,
      editing: layout.cards[1].elements[2].id,
      onDone: {},
      onRemove: {}
    )
    let pages: [(NSAppearance.Name, AnyView)] = [
      (.aqua, AnyView(DashboardView(status: status, history: history, layout: .constant(layout), now: now, actions: actions, scrollsCards: false))),
      (.darkAqua, AnyView(DashboardView(status: status, history: history, layout: .constant(layout), now: now, actions: actions, scrollsCards: false))),
      (.aqua, AnyView(customize)),
      (.aqua, AnyView(elementPage)),
      (.aqua, AnyView(MenuBarSettingsView(status: status, layout: .constant(layout), actions: actions, onDone: {}))),
    ]
    let images = pages.map { name, page -> NSBitmapImageRep? in
      // An offscreen window draws AppKit-backed controls (menus, context
      // menus, forms) that ImageRenderer replaces with placeholders.
      let hosting = NSHostingView(rootView: page.background(Color(nsColor: .windowBackgroundColor)))
      hosting.frame.size = NSSize(width: size.width, height: hosting.fittingSize.height)
      let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.appearance = NSAppearance(named: name)
      window.contentView = hosting
      hosting.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.3))
      guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
      hosting.cacheDisplay(in: hosting.bounds, to: rep)
      return rep
    }.compactMap { $0 }
    guard images.count == pages.count else {
      FileHandle.standardError.write(Data("render-dashboard: rendering failed\n".utf8))
      exit(1)
    }
    let width = images.map(\.pixelsWide).reduce(0, +)
    let height = images.map(\.pixelsHigh).max() ?? 0
    let canvas = NSImage(size: NSSize(width: width, height: height))
    canvas.lockFocus()
    var x = 0
    for rep in images {
      rep.draw(in: NSRect(x: x, y: height - rep.pixelsHigh, width: rep.pixelsWide, height: rep.pixelsHigh))
      x += rep.pixelsWide
    }
    canvas.unlockFocus()
    guard let tiff = canvas.tiffRepresentation,
      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else {
      FileHandle.standardError.write(Data("render-dashboard: encoding failed\n".utf8))
      exit(1)
    }
    do {
      try png.write(to: URL(fileURLWithPath: outputPath))
      print("render-dashboard: wrote \(outputPath)")
    } catch {
      FileHandle.standardError.write(Data("render-dashboard: \(error)\n".utf8))
      exit(1)
    }
  }

  /// Five-minute readings with bursty, monotone usage inside each window and
  /// a reset every five hours for the short limits.
  static func sample(now: Date) -> (UsageStatus, UsageHistory) {
    let start = now.addingTimeInterval(-30 * 3600)
    var history = UsageHistory(persistenceURL: nil, now: start)
    let weekReset = now.addingTimeInterval(2.6 * 24 * 3600)
    let fiveHours: TimeInterval = 5 * 3600
    let anchor = now.addingTimeInterval(1.7 * 3600)
    var used: [String: Double] = [:]
    var resets: [String: Date] = [:]
    var latest: [Provider: [UsageWindow]] = [:]

    func activity(_ t: TimeInterval, phase: Double) -> Double {
      let wave = sin(t / 5400 + phase) + 0.6 * sin(t / 1900 + phase * 2)
      return max(0, wave)
    }

    let specs: [(Provider, WindowSpeed, UsageScope?, Double, Double, Double)] = [
      (.codex, .slow, nil, 41, 0.020, 0.3),
      (.claude, .fast, nil, 0, 0.38, 1.1),
      (.claude, .slow, nil, 52, 0.030, 2.0),
      (.antigravity, .fast, nil, 0, 0.22, 2.7),
      (.antigravity, .slow, nil, 28, 0.012, 0.9),
    ]
    var t = start
    while t <= now {
      var windows: [Provider: [UsageWindow]] = [:]
      for (provider, speed, scope, base, rate, phase) in specs {
        let duration = speed == .slow ? 7 * 24 * 3600 : fiveHours
        let reset = speed == .slow
          ? weekReset
          : anchor.addingTimeInterval(-floor(anchor.timeIntervalSince(t) / fiveHours) * fiveHours)
        let key = "\(provider.rawValue)-\(speed.rawValue)"
        if resets[key] != reset {
          resets[key] = reset
          used[key] = speed == .slow ? base : 0
        }
        used[key] = min(100, (used[key] ?? 0) + activity(t.timeIntervalSince1970, phase: phase) * rate * 5)
        windows[provider, default: []].append(PressureMath.window(
          provider: provider, speed: speed, usedPercent: used[key] ?? 0, resetAt: reset,
          limitWindowSeconds: duration, now: t, scope: scope
        ))
      }
      for (provider, providerWindows) in windows {
        let identity = UsageObservationIdentity(source: "sample", accountPartition: "sample-\(provider.rawValue)", limitIdentity: nil)
        history.record(
          ProviderResult(provider: provider, ok: true, source: "live", error: nil, windows: providerWindows, observationIdentity: identity),
          capturedAt: t
        )
      }
      latest = windows
      t = t.addingTimeInterval(300)
    }

    let results = Provider.allCases.map { provider in
      ProviderResult(
        provider: provider, ok: true, source: "live", error: nil, windows: latest[provider] ?? [],
        observationIdentity: UsageObservationIdentity(source: "sample", accountPartition: "sample-\(provider.rawValue)", limitIdentity: nil)
      )
    }
    return (UsageStatus(generatedAt: now, results: results), history)
  }
}
