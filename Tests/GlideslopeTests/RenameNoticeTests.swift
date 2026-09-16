import Foundation
import Testing
@testable import Glideslope

@Suite("Glideslope to Alight rename notice")
struct RenameNoticeTests {
  @Test("notice is shown once per old installation")
  func noticeMarkerIsIdempotent() {
    let suite = "GlideslopeRenameNoticeTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(GlideslopeRenameNotice.shouldPresent(userDefaults: defaults))
    defaults.set(true, forKey: GlideslopeRenameNotice.markerKey)
    #expect(!GlideslopeRenameNotice.shouldPresent(userDefaults: defaults))
  }

  @Test("notice links to the canonical Alight page")
  func noticeUsesAlightPage() {
    #expect(GlideslopeRenameNotice.alightURL.absoluteString == "https://owlandkestrel.com/apps/alight")
  }
}
