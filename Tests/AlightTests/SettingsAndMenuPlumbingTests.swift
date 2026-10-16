import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Alight

@Suite("Menu, settings and history window plumbing")
struct MenuRowViewsTests {
  @Test("ColorSwatchButton tracks hover, draws swatch, and initializes correctly")
  @MainActor
  func colorSwatchButton() {
    let button = ColorSwatchButton(provider: .codex, color: .systemTeal)
    #expect(button.frame.width == 18)
    #expect(button.frame.height == 18)
    #expect(button.toolTip?.contains("Codex") == true)
    #expect(button.isHovered == false)

    let dummyEvent = NSEvent()
    button.mouseEntered(with: dummyEvent)
    #expect(button.isHovered == true)

    let hoverImage = NSImage(size: button.frame.size)
    hoverImage.lockFocus()
    button.draw(button.bounds)
    hoverImage.unlockFocus()

    button.mouseExited(with: dummyEvent)
    #expect(button.isHovered == false)

    let normalImage = NSImage(size: button.frame.size)
    normalImage.lockFocus()
    button.draw(button.bounds)
    normalImage.unlockFocus()
  }

  @Test("AppSettings providerOrder reorders providers cleanly")
  func providerOrder() {
    let saved = UserDefaults.standard.stringArray(forKey: "providerOrder")
    defer {
      if let saved {
        UserDefaults.standard.set(saved, forKey: "providerOrder")
      } else {
        UserDefaults.standard.removeObject(forKey: "providerOrder")
      }
    }
    UserDefaults.standard.removeObject(forKey: "providerOrder")

    let initialOrder = AppSettings.providerOrder
    #expect(initialOrder.count == 3)

    let first = initialOrder[0]
    let second = initialOrder[1]

    // Move first down
    AppSettings.moveProvider(first, up: false)
    #expect(AppSettings.providerOrder[0] == second)
    #expect(AppSettings.providerOrder[1] == first)

    // Move it back up
    AppSettings.moveProvider(first, up: true)
    #expect(AppSettings.providerOrder[0] == first)
    #expect(AppSettings.providerOrder[1] == second)
  }

  @Test("SettingsWindowController toolbar and tabs initialize correctly")
  @MainActor
  func settingsWindowController() {
    let controller = SettingsWindowController.shared
    #expect(controller.window != nil)
    #expect(controller.window?.title == "Alight Settings")
    #expect(controller.toolbarDefaultItemIdentifiers(controller.window!.toolbar!).count == 4)
  }

  @Test("all gauge controls fit and the update checkbox notifies its updater")
  @MainActor
  func settingsControlsFitAndNotifyUpdater() throws {
    let controller = SettingsWindowController()
    let tabs = try #require(controller.window?.contentView as? NSTabView)
    let gauge = try #require(tabs.tabViewItems.first { ($0.identifier as? String) == "gauge" }?.view as? NSScrollView)
    let canvas = try #require(gauge.documentView)
    #expect(canvas.subviews.compactMap { $0 as? SettingsSliderRow }.count == 12)
    #expect(canvas.subviews.allSatisfy { $0.frame.minY >= 0 && $0.frame.maxY <= canvas.bounds.height })
    let updates = try #require(tabs.tabViewItems.first { ($0.identifier as? String) == "updates" }?.view)
    let checkbox = try #require(updates.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Install updates automatically" })
    var selected: [Bool] = []
    controller.onAutomaticUpdatesChanged = { selected.append($0) }
    for state: NSControl.StateValue in [.on, .off] {
      checkbox.state = state
      #expect(NSApp.sendAction(try #require(checkbox.action), to: checkbox.target, from: checkbox))
      #expect(controller.automaticallyInstallsUpdates == (state == .on))
    }
    #expect(selected == [true, false])
    // Optional bounded offscreen QA: no status controller, poller, updater or
    // real settings setter is created. The checkbox uses the fake callback.
    if let output = ProcessInfo.processInfo.environment["ALIGHT_SAFE_UI_QA_DIR"] {
      let directory = URL(fileURLWithPath: output, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      for (name, view) in [("gauge-controls", canvas), ("updates-controls", updates)] {
        tabs.selectTabViewItem(withIdentifier: name == "gauge-controls" ? "gauge" : "updates")
        view.appearance = NSAppearance(named: .aqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.cgColor
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appending(path: "\(name).png"))
      }
    }
  }

  @Test("menu countdown and hover timers fire during event tracking")
  @MainActor
  func trackingTimersFire() {
    for repeats in [false, true] {
      let probe = MenuCallbackProbe()
      let timer = MenuTrackingTimer.scheduled(timeInterval: 0.01, target: probe,
        selector: #selector(MenuCallbackProbe.timerFired(_:)), userInfo: nil, repeats: repeats)
      defer { timer.invalidate() }
      let deadline = Date().addingTimeInterval(0.2)
      while probe.calls == 0 && Date() < deadline {
        RunLoop.main.run(mode: .eventTracking, before: deadline)
      }
      #expect(probe.calls > 0)
    }
  }

  @Test("Usage History is visible and dispatches its menu action")
  @MainActor
  func usageHistoryMenuDispatch() {
    _ = NSApplication.shared
    let menu = NSMenu()
    menu.autoenablesItems = false
    let probe = MenuCallbackProbe()
    let item = StatusItemController.usageHistoryMenuItem(target: probe)
    menu.addItem(item)
    #expect(item.title == "Usage History…")
    #expect(!item.isHidden && item.isEnabled)
    menu.performActionForItem(at: 0)
    #expect(probe.calls == 1)
  }

  @Test("history window reopens with the same host and canonical store")
  @MainActor
  func usageHistoryWindowReopens() throws {
    _ = NSApplication.shared
    let store = UsageStore(history: UsageHistory(persistenceURL: nil),
      resultCache: UsageResultCache(persistenceURL: nil))
    let controller = UsageInsightsWindowController(store: store, frameAutosaveName: nil)
    let window = try #require(controller.window)
    // Keep the synthetic test window offscreen, with no frame preference write
    // or application activation. No StatusItemController/poller/updater exists.
    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    defer { window.orderOut(nil); window.close() }
    let host = try #require(window.contentViewController as? NSHostingController<UsageInsightsView>)
    #expect(host.rootView.store === store)
    #expect(!window.isReleasedWhenClosed)
    controller.showWindow(nil)
    #expect(window.isVisible)
    window.close()
    #expect(!window.isVisible)
    store.status = UsageStatus(generatedAt: Date(), results: [])
    controller.showWindow(nil)
    #expect(window.isVisible)
    #expect(controller.window === window)
    #expect(window.contentViewController === host)
    #expect(host.rootView.store === store)
    #expect(store.history.observations.isEmpty)
  }

  @Test("Secondary group buckets format clean 3P labels")
  func secondaryBucketLabels() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payload: [String: Any] = [
      "groups": [
        [
          "displayName": "Gemini Models",
          "buckets": [
            [
              "bucketId": "gemini-5h",
              "window": "5h",
              "resetTime": "2027-01-15T09:00:00Z",
              "remainingFraction": 0.80
            ],
            [
              "bucketId": "gemini-weekly",
              "window": "weekly",
              "resetTime": "2027-01-20T09:00:00Z",
              "remainingFraction": 0.90
            ]
          ]
        ],
        [
          "displayName": "Claude and GPT models",
          "buckets": [
            [
              "bucketId": "3p-weekly",
              "displayName": "Weekly Limit Remaining",
              "window": "weekly",
              "resetTime": "2027-01-22T09:00:00Z",
              "remainingFraction": 0.20
            ],
            [
              "bucketId": "3p-5h",
              "displayName": "Five Hour Limit Remaining",
              "window": "5h",
              "resetTime": "2027-01-16T09:00:00Z",
              "remainingFraction": 0.70
            ]
          ]
        ]
      ]
    ]

    let windows = AntigravityUsageParser.windows(from: payload, now: now)
    let weekly3p = windows.first { $0.scope?.key == "3p-weekly" }
    #expect(weekly3p?.label == "3P Models (Weekly)")

    let fast3p = windows.first { $0.scope?.key == "3p-5h" }
    #expect(fast3p?.label == "3P Models (5h)")
  }

}

@MainActor
private final class MenuCallbackProbe: NSObject {
  var calls = 0
  @objc func timerFired(_ sender: Timer) { calls += 1 }
  @objc func openUsageHistory() { calls += 1 }
}
