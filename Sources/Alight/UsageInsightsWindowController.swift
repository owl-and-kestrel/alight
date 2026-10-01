import AppKit
import SwiftUI

/// Thin host for the reusable chart. The menu retains this controller and passes
/// its existing store, so opening or reopening the window adds no poller.
@MainActor
final class UsageInsightsWindowController: NSWindowController {
  init(store: UsageStore, frameAutosaveName: String? = "AlightUsageInsights") {
    let content = NSHostingController(rootView: UsageInsightsView(store: store))
    let window = NSWindow(contentViewController: content)
    window.title = "Alight Usage Insights"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.setContentSize(NSSize(width: 760, height: 720))
    if let frameAutosaveName { window.setFrameAutosaveName(frameAutosaveName) }
    window.isReleasedWhenClosed = false
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init(store:)") }

  func showInsights() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
