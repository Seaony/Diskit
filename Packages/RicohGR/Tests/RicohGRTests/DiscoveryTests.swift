import Core
import Foundation
import Testing

@testable import RicohGR

@Test @MainActor func discoveryPublishesUniqueLocationsAndClearsOnStop() {
  var starts = 0
  var stops = 0
  let discovery = RicohDiscovery(start: { _ in starts += 1 }, stop: { stops += 1 })
  var snapshots: [[RicohDevice]] = []
  discovery.changed = { snapshots.append($0) }
  discovery.start()
  discovery.start()
  #expect(starts == 1)
  #expect(
    discovery.discovered(name: "GR III", serial: "s", location: 1, uuid: nil, persistent: nil)
      == nil)
  #expect(
    discovery.discovered(name: "GR IV", serial: "s", location: 0, uuid: nil, persistent: nil) == nil
  )
  #expect(
    discovery.discovered(name: "GR IV", serial: "same", location: 1, uuid: nil, persistent: nil)
      == "usb:1")
  discovery.discovered(name: "RICOH GR IV", serial: "same", location: 2, uuid: nil, persistent: nil)
  discovery.discovered(name: "GR IV", serial: "changed", location: 1, uuid: nil, persistent: nil)
  #expect(discovery.devices.count == 2)
  #expect(discovery.devices.first?.serial == "changed")
  #expect(discovery.camera(identifier: "unknown") == nil)
  discovery.removed(id: "usb:1")
  #expect(discovery.devices.map(\.id) == ["usb:2"])
  discovery.stop()
  #expect(discovery.devices.isEmpty)
  #expect(snapshots.last == [])
  #expect(stops == 1)
  discovery.start()
  #expect(starts == 2)
  discovery.stop()
}

@Test @MainActor func discoveryEnumerationReportsCompletionFailureAndStopCancellation() async throws
{
  let success = RicohDiscovery(start: { $0.completeEnumeration(.success(())) }, stop: {})
  try await success.enumerate()
  #expect(success.issue == nil)
  success.stop()
  let failure = RicohDiscovery(
    start: { $0.completeEnumeration(.failure(RemoteError.posix(ETIMEDOUT))) }, stop: {})
  await #expect(throws: RemoteError.posix(ETIMEDOUT)) { try await failure.enumerate() }
  #expect(failure.issue == .failed)
  failure.stop()
  let stopped = RicohDiscovery(start: { $0.stop() }, stop: {})
  await #expect(throws: CancellationError.self) { try await stopped.enumerate() }
  #expect(stopped.issue == nil)
}
