import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Alight

@Suite("Menu row views")
struct MenuRowViewsTests {
  @Test("ProviderHeaderRowView initializes and renders for all provider states")
  @MainActor
  func providerHeaderRow() {
    let liveResult = ProviderResult(
      provider: .claude,
      ok: true,
      source: "live",
      error: nil,
      windows: []
    )
    let cachedResult = ProviderResult(
      provider: .codex,
      ok: true,
      source: "cached",
      error: nil,
      windows: [],
      cacheAgeSeconds: 300
    )
    let authResult = ProviderResult(
      provider: .antigravity,
      ok: false,
      source: "error",
      error: "Not signed in",
      windows: [],
      needsAuth: true
    )

    let liveView = ProviderHeaderRowView(provider: .claude, color: .systemOrange, result: liveResult)
    #expect(liveView.frame.width == 286)
    #expect(liveView.frame.height == 26)
    #expect(liveView.isFlipped == true)

    let cachedView = ProviderHeaderRowView(provider: .codex, color: .systemTeal, result: cachedResult)
    #expect(cachedView.frame.width == 286)

    let authView = ProviderHeaderRowView(provider: .antigravity, color: .systemPurple, result: authResult)
    #expect(authView.frame.width == 286)

    // Verify drawing to image context works without error
    let image = NSImage(size: liveView.frame.size)
    image.lockFocus()
    liveView.draw(liveView.bounds)
    cachedView.draw(cachedView.bounds)
    authView.draw(authView.bounds)
    image.unlockFocus()
  }

  @Test("UsageWindowRowView formats pace display and draws in both fill modes")
  @MainActor
  func usageWindowRow() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let weeklyWindow = PressureMath.window(
      provider: .codex,
      speed: .slow,
      usedPercent: 80,
      resetAt: now.addingTimeInterval(3600 * 24 * 3),
      limitWindowSeconds: 3600 * 24 * 7,
      now: now
    )

    let fillView = UsageWindowRowView(
      window: weeklyWindow,
      accentColor: .systemTeal,
      fillMode: .fill,
      now: now
    )
    #expect(fillView.frame.width == 286)
    #expect(fillView.frame.height == 36)
    #expect(fillView.isFlipped == true)
    #expect(fillView.toolTip?.contains("Resets") == true)

    let emptyView = UsageWindowRowView(
      window: weeklyWindow,
      accentColor: .systemTeal,
      fillMode: .empty,
      now: now
    )
    #expect(emptyView.frame.width == 286)

    let image = NSImage(size: fillView.frame.size)
    image.lockFocus()
    fillView.draw(fillView.bounds)
    emptyView.draw(emptyView.bounds)
    image.unlockFocus()
  }

  @Test("Fable star window row draws star indicator")
  @MainActor
  func fableStarRow() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let fableWindow = PressureMath.window(
      provider: .claude,
      speed: .slow,
      usedPercent: 20,
      resetAt: now.addingTimeInterval(3600 * 24 * 4),
      limitWindowSeconds: 3600 * 24 * 7,
      now: now,
      scope: .fable,
      visualStyle: .outerStar
    )

    let fableView = UsageWindowRowView(
      window: fableWindow,
      accentColor: .systemOrange,
      fillMode: .fill,
      now: now
    )
    #expect(fableView.frame.width == 286)

    let image = NSImage(size: fableView.frame.size)
    image.lockFocus()
    fableView.draw(fableView.bounds)
    image.unlockFocus()
  }

  @Test("ProviderStatusRowView and ProviderNoteRowView initialize with correct metrics")
  @MainActor
  func statusAndNoteRows() {
    let note = ProviderNoteRowView(text: "Last live 5m ago; rate-limited")
    #expect(note.frame.width == 286)
    #expect(note.frame.height == 16)
    #expect(note.isFlipped == true)

    let status = ProviderStatusRowView(reason: "Usage unavailable")
    #expect(status.frame.width == 286)
    #expect(status.frame.height == 22)
    #expect(status.isFlipped == true)
  }

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

  @Test("MenuIconButton handles hover, click, and drawing states")
  @MainActor
  func menuIconButton() {
    var clickCount = 0
    var hoverIntentFired = false

    let button = MenuIconButton(
      frame: NSRect(x: 0, y: 0, width: 22, height: 22),
      symbolName: "gearshape.fill",
      fallbackSymbolName: "gearshape",
      toolTip: "Settings",
      onClick: { clickCount += 1 },
      onHoverIntent: { hoverIntentFired = true }
    )

    #expect(button.frame.width == 22)
    #expect(button.frame.height == 22)
    #expect(button.isHovered == false)
    #expect(button.isPressed == false)
    #expect(hoverIntentFired == false)

    let dummyEvent = NSEvent()

    // Test mouseEntered
    button.mouseEntered(with: dummyEvent)
    #expect(button.isHovered == true)

    // Test draw in hover state
    let hoverImage = NSImage(size: button.frame.size)
    hoverImage.lockFocus()
    button.draw(button.bounds)
    hoverImage.unlockFocus()

    // Test click on mouseDown
    button.mouseDown(with: dummyEvent)
    #expect(clickCount == 1)

    // Test mouseExited
    button.mouseExited(with: dummyEvent)
    #expect(button.isHovered == false)
    #expect(button.isPressed == false)
  }

  @Test("MenuFooterRowView initializes with correct layout")
  @MainActor
  func menuFooterRow() {
    var refreshed = false
    var gearClicked = false

    let footer = MenuFooterRowView(
      statusText: "Alight · Updated just now",
      onRefresh: { refreshed = true },
      onGearClick: { gearClicked = true }
    )
    #expect(footer.frame.width == 286)
    #expect(footer.frame.height == 26)
    #expect(footer.isFlipped == true)
    #expect(footer.subviews.count == 3)
    #expect(refreshed == false)
    #expect(gearClicked == false)
  }

  @Test("UsageWindowRowView formats DD:HH:MM:SS countdown correctly")
  @MainActor
  func countdownFormat() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    // 3 days, 14 hours, 22 minutes, 10 seconds
    let resetIn3Days = now.addingTimeInterval(3 * 86400 + 14 * 3600 + 22 * 60 + 10)
    #expect(UsageWindowRowView.formatCountdown(resetAt: resetIn3Days, now: now) == "03:14:22:10")

    // Past or zero
    let past = now.addingTimeInterval(-10)
    #expect(UsageWindowRowView.formatCountdown(resetAt: past, now: now) == "00:00:00:00")

    // 4 hours, 15 minutes, 30 seconds
    let resetIn4Hours = now.addingTimeInterval(4 * 3600 + 15 * 60 + 30)
    #expect(UsageWindowRowView.formatCountdown(resetAt: resetIn4Hours, now: now) == "00:04:15:30")
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

  @Test("hidden command shortcuts remain dispatchable")
  @MainActor
  func hiddenKeyboardShortcut() throws {
    _ = NSApplication.shared
    let menu = NSMenu()
    menu.autoenablesItems = false
    let probe = MenuCallbackProbe()
    let item = StatusItemController.keyboardShortcut(title: "Refresh", action: #selector(MenuCallbackProbe.menuInvoked(_:)), key: "r")
    item.target = probe
    menu.addItem(item)
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
      characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15))
    #expect(item.isHidden)
    #expect(menu.performKeyEquivalent(with: event))
    #expect(probe.calls == 1)
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
  @objc func menuInvoked(_ sender: NSMenuItem) { calls += 1 }
  @objc func openUsageHistory() { calls += 1 }
}
