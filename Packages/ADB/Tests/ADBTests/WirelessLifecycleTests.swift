import Core
import Foundation
import Network
import Testing
@testable import ADB

@MainActor
private final class DiscoveryDriverFake: WirelessDiscoveryDriver {
  var snapshots: [WirelessServiceType: @MainActor ([WirelessDevice]) -> Void] = [:]
  var failures: [WirelessServiceType: @MainActor (NWError) -> Void] = [:]
  var resolutions: [String: @MainActor (Result<(String?, Int), Error>) -> Void] = [:]
  var stoppedResolutions: [String] = []
  var starts = 0
  var stops = 0
  var startWaiter: CheckedContinuation<Void, Never>?
  func start(type: WirelessServiceType, snapshot: @escaping @MainActor ([WirelessDevice]) -> Void,
             failure: @escaping @MainActor (NWError) -> Void) {
    starts += 1; snapshots[type] = snapshot; failures[type] = failure
    startWaiter?.resume(); startWaiter = nil
  }
  func resolve(_ device: WirelessDevice, completion: @escaping @MainActor (Result<(String?, Int), Error>) -> Void) {
    resolutions[device.id] = completion
  }
  func stopResolution(_ id: String) { stoppedResolutions.append(id); resolutions.removeValue(forKey: id) }
  func stop() { stops += 1 }
  func started() async {
    if starts > 0 { return }
    await withCheckedContinuation { startWaiter = $0 }
  }
}
private actor DiscoveryGate {
  var opened = false
  var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if opened { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() { opened = true; for waiter in waiters { waiter.resume() }; waiters = [] }
}

@Test @MainActor func wirelessLifecycleCombinesSnapshotsAndRetainsResolvedAddress() throws {
  let driver = DiscoveryDriverFake()
  let discovery = WirelessDiscovery(driver: driver)
  var publications = 0
  discovery.changed = { _ in publications += 1 }
  discovery.start(); discovery.start()
  #expect(driver.starts == 2)
  let pair = WirelessDevice(name: "pair", type: .pairing)
  let connect = WirelessDevice(name: "phone", type: .connect)
  driver.snapshots[.pairing]?([pair])
  driver.snapshots[.connect]?([connect])
  driver.resolutions[connect.id]?(.success(("phone.local", 1234)))
  driver.snapshots[.connect]?([connect])
  #expect(discovery.devices.count == 2)
  #expect(discovery.devices.first(where: { $0.id == connect.id })?.host == "phone.local")
  #expect(discovery.devices.first(where: { $0.id == connect.id })?.port == 1234)
  driver.snapshots[.pairing]?([])
  #expect(driver.stoppedResolutions == [pair.id])
  #expect(discovery.devices.map(\.id) == [connect.id])
  #expect(publications >= 5)
  discovery.stop()
  #expect(driver.stops == 1)
  #expect(discovery.devices.isEmpty && discovery.issue == nil && discovery.error == nil)
}

@Test @MainActor func wirelessLateCallbacksCannotReviveStoppedOrReplacedDevices() throws {
  let driver = DiscoveryDriverFake()
  let discovery = WirelessDiscovery(driver: driver)
  discovery.start()
  let device = WirelessDevice(name: "phone", type: .connect)
  let oldSnapshot = try #require(driver.snapshots[.connect])
  let oldFailure = try #require(driver.failures[.connect])
  oldSnapshot([device])
  let oldResolve = try #require(driver.resolutions[device.id])
  oldSnapshot([]); oldSnapshot([device])
  oldResolve(.success(("stale.local", 456)))
  #expect(discovery.devices.first?.host == nil)
  discovery.stop(); discovery.start()
  oldSnapshot([device]); oldFailure(.posix(.EPERM)); oldResolve(.failure(RemoteError.protocolError))
  #expect(discovery.devices.isEmpty && discovery.issue == nil)
}

@Test @MainActor func wirelessInvalidResolvedPortsAndTypedFailuresAreVisible() {
  let driver = DiscoveryDriverFake()
  let discovery = WirelessDiscovery(driver: driver)
  discovery.start()
  let device = WirelessDevice(name: "phone", type: .connect)
  driver.snapshots[.connect]?([device])
  for port in [-1, 0, 65536] {
    driver.resolutions[device.id]?(.success(("host", port)))
    #expect(discovery.devices.first?.port == nil)
  }
  driver.resolutions[device.id]?(.failure(RemoteError.protocolError))
  #expect(discovery.issue == .resolutionFailed && discovery.error != nil)
  for error in [NWError.posix(.EACCES), .posix(.EPERM), .dns(-65570)] {
    driver.failures[.connect]?(error)
    #expect(discovery.issue == .permissionDenied)
  }
  for error in [NWError.posix(.ENETDOWN), .posix(.ENETUNREACH), .posix(.ENOTCONN)] {
    driver.failures[.connect]?(error)
    #expect(discovery.issue == .networkUnavailable)
  }
  driver.failures[.connect]?(.posix(.EIO))
  #expect(discovery.issue == .failed)
}

@Test @MainActor func wirelessResolverMatchesFullGUIDAndStopsAfterSuccess() async throws {
  let driver = DiscoveryDriverFake()
  let gate = DiscoveryGate()
  let resolver = WirelessResolver(guid: "adb-phone-ABC123", driver: driver, sleep: { await gate.wait() })
  let task = Task { try await resolver.run() }
  await driver.started()
  driver.snapshots[.connect]?([WirelessDevice(name: "wrong", type: .connect), WirelessDevice(name: "adb-phone-ABC123", type: .pairing)])
  #expect(driver.stops == 0)
  let device = WirelessDevice(name: "adb-phone-ABC123", type: .connect)
  driver.snapshots[.connect]?([device])
  #expect(try await task.value == device.endpoint)
  driver.failures[.connect]?(.posix(.EIO))
  #expect(driver.stops == 1)
  await gate.open()
}

@Test @MainActor func wirelessResolverTimeoutAndCancellationStopDriver() async throws {
  for cancel in [false, true] {
    let driver = DiscoveryDriverFake()
    let gate = DiscoveryGate()
    let resolver = WirelessResolver(guid: "phone", driver: driver, sleep: { await gate.wait() })
    let task = Task { try await resolver.run() }
    await driver.started()
    if cancel { task.cancel() } else { await gate.open() }
    if cancel {
      await #expect(throws: CancellationError.self) { _ = try await task.value }
    } else {
      await #expect(throws: RemoteError.posix(ETIMEDOUT)) { _ = try await task.value }
    }
    #expect(driver.stops == 1)
    await gate.open()
  }
}

@Test @MainActor func wirelessResolverRejectsInvalidBusyAndBrowserFailure() async throws {
  let driver = DiscoveryDriverFake()
  let gate = DiscoveryGate()
  let invalid = WirelessResolver(guid: "", driver: driver, sleep: { await gate.wait() })
  await #expect(throws: RemoteError.invalidPath) { _ = try await invalid.run() }
  let resolver = WirelessResolver(guid: "phone", driver: driver, sleep: { await gate.wait() })
  let task = Task { try await resolver.run() }
  await driver.started()
  await #expect(throws: RemoteError.posix(EBUSY)) { _ = try await resolver.run() }
  driver.failures[.connect]?(.posix(.ENETDOWN))
  await #expect(throws: NWError.posix(.ENETDOWN)) { _ = try await task.value }
  #expect(driver.stops == 1)
  await gate.open()
}
