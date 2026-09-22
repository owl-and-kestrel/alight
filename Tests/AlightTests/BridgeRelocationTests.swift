import Foundation
import Testing
@testable import Alight

@Suite("Glideslope bridge relocation")
struct BridgeRelocationTests {
  private func target(
    bundle: String,
    existing: Set<String> = [],
    writable: Bool = true
  ) -> URL? {
    BridgeRelocation.relocationTarget(
      bundleURL: URL(fileURLWithPath: bundle),
      fileExists: { existing.contains($0) },
      isWritableDirectory: { _ in writable }
    )
  }

  @Test("a bridged install at Glideslope.app moves to Alight.app beside it")
  func renamesLegacyBundle() {
    #expect(target(bundle: "/Applications/Glideslope.app")?.path == "/Applications/Alight.app")
    #expect(target(bundle: "/Users/me/Apps/glideslope.app")?.path == "/Users/me/Apps/Alight.app")
  }

  @Test("no rename when already Alight, when Alight.app exists, or when read-only")
  func leavesOtherBundlesAlone() {
    #expect(target(bundle: "/Applications/Alight.app") == nil)
    #expect(target(bundle: "/Applications/Glideslope.app", existing: ["/Applications/Alight.app"]) == nil)
    #expect(target(bundle: "/Applications/Glideslope.app", writable: false) == nil)
  }
}
