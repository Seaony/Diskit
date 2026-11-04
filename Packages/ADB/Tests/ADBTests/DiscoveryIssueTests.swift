import Foundation
import Network
import Testing

@testable import ADB

@Test @MainActor func wirelessDiscoveryClassifiesTypedFailures() {
  #expect(WirelessDiscovery.discoveryIssue(.posix(.EACCES)) == .permissionDenied)
  #expect(WirelessDiscovery.discoveryIssue(.dns(-65570)) == .permissionDenied)
  #expect(WirelessDiscovery.discoveryIssue(.posix(.ENETDOWN)) == .networkUnavailable)
  #expect(WirelessDiscovery.discoveryIssue(.posix(.EIO)) == .failed)
}
