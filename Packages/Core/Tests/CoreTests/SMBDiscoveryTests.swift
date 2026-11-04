import Foundation
import Network
import Testing
import dnssd

@testable import Core

@MainActor private final class FakeSMBBrowser: SMBDiscoveryBrowsing {
  var event: ((SMBBrowseEvent) -> Void)?
  var starts = 0
  var cancellations = 0
  func start() { starts += 1 }
  func cancel() { cancellations += 1 }
}

@MainActor @Test func smbBrowserFailureAllowsRestartAndIgnoresOldEvents() {
  let first = FakeSMBBrowser()
  let second = FakeSMBBrowser()
  var browsers = [first, second]
  let discovery = SMBDiscovery(makeBrowser: { browsers.removeFirst() }, resolve: { _, _ in })
  discovery.start()
  let old = first.event
  first.event?(.failed(.permissionDenied))
  #expect(first.cancellations == 1)
  #expect(discovery.issue == .permissionDenied)
  discovery.start()
  #expect(second.starts == 1)
  old?(.results([SMBServiceRecord(name: "old", type: "_smb._tcp", domain: "local.")]))
  #expect(discovery.devices.isEmpty)
  second.event?(.ready)
  #expect(discovery.issue == nil)
  discovery.stop()
  #expect(second.cancellations == 1)
}

@MainActor @Test func smbResolutionRetriesAndKeepsSuccessfulHost() async {
  let browser = FakeSMBBrowser()
  var services: [NetService] = []
  var next: CheckedContinuation<Void, Never>?
  let discovery = SMBDiscovery(
    makeBrowser: { browser },
    resolve: { service, timeout in
      #expect(timeout == RemoteTimeout.deviceRequest)
      services.append(service)
      next?.resume()
      next = nil
    }, retryDelay: .zero)
  let record = SMBServiceRecord(name: "local fixture", type: "_smb._tcp", domain: "local.")
  discovery.start()
  browser.event?(.results([record]))
  let first = services[0]
  await withCheckedContinuation { continuation in
    next = continuation
    discovery.netService(first, didNotResolve: [:])
  }
  let second = services[1]
  #expect(discovery.issue == .resolutionFailed)
  discovery.resolved(second, host: "fixture.invalid.")
  #expect(discovery.devices.first?.host == "fixture.invalid.")
  #expect(discovery.issue == nil)
  browser.event?(.results([record]))
  #expect(services.count == 2)
  #expect(discovery.devices.first?.host == "fixture.invalid.")
  discovery.stop()
}

@MainActor @Test func smbResolutionStopsRetryingAfterThreeAttempts() async {
  let browser = FakeSMBBrowser()
  var services: [NetService] = []
  var next: CheckedContinuation<Void, Never>?
  let discovery = SMBDiscovery(
    makeBrowser: { browser },
    resolve: { service, _ in
      services.append(service)
      next?.resume()
      next = nil
    }, retryDelay: .zero)
  let record = SMBServiceRecord(name: "local fixture", type: "_smb._tcp", domain: "local.")
  discovery.start()
  browser.event?(.results([record]))
  var current = services[0]
  for _ in 0..<2 {
    await withCheckedContinuation { continuation in
      next = continuation
      discovery.netService(current, didNotResolve: [:])
    }
    current = services.last!
  }
  discovery.netService(current, didNotResolve: [:])
  browser.event?(.results([record]))
  #expect(services.count == 3)
  #expect(discovery.issue == .resolutionFailed)
  discovery.stop()
}

@MainActor @Test func removedSMBServiceCancelsPendingResolutionRetry() async {
  let browser = FakeSMBBrowser()
  var services: [NetService] = []
  let discovery = SMBDiscovery(
    makeBrowser: { browser }, resolve: { service, _ in services.append(service) },
    retryDelay: .seconds(3600))
  discovery.start()
  browser.event?(
    .results([SMBServiceRecord(name: "local fixture", type: "_smb._tcp", domain: "local.")]))
  let service = services[0]
  discovery.netService(service, didNotResolve: [:])
  browser.event?(.results([]))
  discovery.resolved(service, host: "late.invalid")
  await Task.yield()
  #expect(services.count == 1)
  #expect(discovery.devices.isEmpty)
  #expect(discovery.issue == nil)
  discovery.stop()
}

@Test func smbDiscoveryClassifiesPermissionAndConnectivityFailures() {
  #expect(SMBDiscoveryIssue.from(.posix(.EACCES)) == .permissionDenied)
  #expect(SMBDiscoveryIssue.from(.dns(Int32(kDNSServiceErr_PolicyDenied))) == .permissionDenied)
  #expect(SMBDiscoveryIssue.from(.dns(Int32(kDNSServiceErr_NoRouter))) == .networkUnavailable)
  #expect(SMBDiscoveryIssue.from(.posix(.ENETDOWN)) == .networkUnavailable)
  #expect(SMBDiscoveryIssue.from(.posix(.EIO)) == .failed)
}
