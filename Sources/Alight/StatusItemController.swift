import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
  private let statusItem = NSStatusBar.system.statusItem(withLength: 24)
  private let store = UsageStore()
  private let updater = AppUpdater()
  private let layoutStore = DashboardLayoutStore()
  private let popover = NSPopover()
  private lazy var usageInsightsWindow = UsageInsightsWindowController(store: store)

  override init() {
    super.init()
    if let button = statusItem.button {
      button.bezelStyle = .regularSquare
      button.isBordered = false
      button.imagePosition = .imageOnly
      button.imageScaling = .scaleProportionallyDown
      button.toolTip = "Alight"
      button.target = self
      button.action = #selector(statusItemClicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    popover.behavior = .transient
    popover.animates = true
    popover.delegate = self
    let hosting = NSHostingController(rootView: DashboardRoot(store: store, layoutStore: layoutStore, actions: dashboardActions))
    // The popover follows the SwiftUI content's ideal size (cards added,
    // removed, customized).
    hosting.sizingOptions = [.preferredContentSize]
    popover.contentViewController = hosting

    layoutStore.onChange = { [weak self] in self?.updateIcon() }

    SettingsWindowController.shared.onSettingChanged = { [weak self] in
      self?.applyIconSettingChange()
    }
    SettingsWindowController.shared.onCheckForUpdates = { [weak self] in
      self?.updater.checkForUpdates()
    }
    SettingsWindowController.shared.onAutomaticUpdatesChanged = { [weak self] enabled in
      self?.updater.setAutomaticallyInstallsUpdates(enabled)
    }
    SettingsWindowController.shared.automaticallyInstallsUpdates = updater.automaticallyInstallsUpdates

    updateIcon()
    #if DEBUG
    installDebugHooks()
    #endif

    Task {
      await store.refresh()
      updateIcon()
      startRefreshLoop()
    }
  }

  private var dashboardActions: DashboardActions {
    DashboardActions(
      refresh: { [weak self] in self?.refresh() },
      openSettings: { [weak self] in self?.openSettingsWindow() },
      openHistory: { [weak self] in self?.openUsageHistory() },
      checkForUpdates: { [weak self] in
        self?.popover.performClose(nil)
        self?.updater.checkForUpdates()
      },
      quit: { NSApplication.shared.terminate(nil) },
      signIn: { [weak self] provider in
        self?.popover.performClose(nil)
        CLISignIn.launch(provider)
      },
      color: { provider in Color(nsColor: GaugeIconRenderer.providerColor(provider, style: AppSettings.iconStyle)) }
    )
  }

  private func startRefreshLoop() {
    Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        await store.refresh()
        updateIcon()
      }
    }
  }

  // MARK: Status item

  @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    if NSApp.currentEvent?.type == .rightMouseUp {
      showContextMenu()
    } else {
      togglePopover()
    }
  }

  private func togglePopover() {
    guard let button = statusItem.button else { return }
    if popover.isShown {
      popover.performClose(nil)
    } else {
      NSApp.activate(ignoringOtherApps: true)
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      popover.contentViewController?.view.window?.makeKey()
      button.highlight(true)
    }
  }

  func popoverDidClose(_ notification: Notification) {
    statusItem.button?.highlight(false)
  }

  /// Right-click: the essentials without opening the dashboard.
  private func showContextMenu() {
    let menu = NSMenu()
    menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
    menu.addItem(Self.usageHistoryMenuItem(target: self))
    menu.addItem(withTitle: "Settings…", action: #selector(openSettingsWindow), keyEquivalent: ",").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Alight", action: #selector(quit), keyEquivalent: "q").target = self
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  static func usageHistoryMenuItem(target: AnyObject) -> NSMenuItem {
    let item = NSMenuItem(title: "Usage History…", action: #selector(openUsageHistory), keyEquivalent: "")
    item.target = target
    return item
  }

  private func updateIcon() {
    // The icon draws only the most relevant windows; the tooltip still
    // summarizes everything.
    let shown = MenuBarRelevance.select(status: store.status, layout: layoutStore.layout)
    let mode = AppSettings.displayMode
    let image: NSImage
    switch mode {
    case .gauge:
      statusItem.length = 24
      image = GaugeIconRenderer.image(status: shown, style: AppSettings.iconStyle)
    case .meters:
      let style = AppSettings.meterStyle
      statusItem.length = MeterIconRenderer.size(for: style).width + 6
      image = MeterIconRenderer.image(status: shown, style: style)
    }
    statusItem.button?.image = image
    statusItem.button?.toolTip = store.status.summary
  }

  private func applyIconSettingChange() {
    layoutStore.appearanceRevision += 1
    updateIcon()
  }

  // MARK: Actions

  @objc private func openSettingsWindow() {
    popover.performClose(nil)
    SettingsWindowController.shared.show()
  }

  @objc private func refresh() {
    Task {
      await store.refresh(force: true)
      updateIcon()
    }
  }

  @objc private func openUsageHistory() {
    popover.performClose(nil)
    usageInsightsWindow.showInsights()
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }

  #if DEBUG
  /// Development builds only: inspect the live popover without Accessibility
  /// or Screen Recording access. Post the distributed notification
  /// `com.owlandkestrel.alight.debug` with an object of `show`, `close`, or
  /// `snapshot:<png path>` (opens the popover and draws its window), or
  /// `status:<path>` (writes each provider's result, errors included).
  private func installDebugHooks() {
    DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("com.owlandkestrel.alight.debug"), object: nil, queue: .main
    ) { [weak self] notification in
      let command = notification.object as? String ?? ""
      MainActor.assumeIsolated { self?.debugCommand(command) }
    }
  }

  private func debugCommand(_ command: String) {
    if command == "close" {
      popover.performClose(nil)
      return
    }
    if command.hasPrefix("status:") {
      let lines = store.status.results.map { result in
        "\(result.provider.rawValue) ok=\(result.ok) source=\(result.source) needsAuth=\(result.needsAuth) " +
          "windows=\(result.windows.map(\.id)) error=\(result.error ?? "none")"
      }
      try? lines.joined(separator: "\n").write(toFile: String(command.dropFirst("status:".count)), atomically: true, encoding: .utf8)
      return
    }
    if !popover.isShown { togglePopover() }
    guard command.hasPrefix("snapshot:") else { return }
    let path = String(command.dropFirst("snapshot:".count))
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
      MainActor.assumeIsolated {
        guard let view = self?.popover.contentViewController?.view,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
      }
    }
  }
  #endif
}
