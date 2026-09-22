import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private static let sharedDelegate = AppDelegate()
  private var controller: StatusItemController?

  static func main() {
    let arguments = CommandLine.arguments
    if let renderPlateIndex = arguments.firstIndex(of: "--render-plate") {
      let output = renderPlateIndex + 1 < arguments.count ? arguments[renderPlateIndex + 1] : "alight-plate.png"
      RenderHarness.runPlate(outputPath: output)
      return
    }
    if let renderIndex = arguments.firstIndex(of: "--render") {
      let output = renderIndex + 1 < arguments.count ? arguments[renderIndex + 1] : "alight-preview.png"
      RenderHarness.run(outputPath: output)
      return
    }
    if let renderMetersIndex = arguments.firstIndex(of: "--render-meters") {
      let output = renderMetersIndex + 1 < arguments.count ? arguments[renderMetersIndex + 1] : "alight-meters-preview.png"
      RenderHarness.runMeters(outputPath: output)
      return
    }

    let app = NSApplication.shared
    app.delegate = sharedDelegate
    app.setActivationPolicy(.accessory)
    app.run()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    DispatchQueue.main.async {
      // An installation bridged from the Glideslope feed still lives at
      // Glideslope.app; take the new name first, then continue as Alight.
      if BridgeRelocation.relocateIfNeeded() {
        NSApp.terminate(nil)
        return
      }
      AlightMigrationNotice.presentIfNeeded()
      self.controller = StatusItemController()
    }
  }
}
