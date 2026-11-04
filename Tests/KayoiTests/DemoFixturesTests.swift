import Core
import Foundation
import Testing

@Test func demoFixturesCoverStatesAndKeepStableIdentities() {
  let mixed = DemoFixtures(scenario: "mixed")
  #expect(mixed.connections.count == 20)
  #expect(Set(mixed.connections.map(\.id)).count == 20)
  #expect(mixed.connections == DemoFixtures(scenario: "mixed").connections)
  #expect(mixed.states.values.contains(.awaitingAuthorization))
  #expect(mixed.states.values.contains(.ejecting))
  #expect(mixed.states.values.contains(.unavailable))
  for connection in mixed.connections {
    if case .mounted = mixed.states[connection.id] { #expect(connection.kind.usesSystemMount) }
    if case .ejecting = mixed.states[connection.id] { #expect(connection.kind.usesSystemMount) }
    if case .awaitingAuthorization = mixed.states[connection.id] {
      #expect(connection.kind == .androidUSB)
    }
  }
  #expect(DemoFixtures(scenario: "empty").connections.isEmpty)
  #expect(DemoFixtures(scenario: "discovered").connections.isEmpty)
  #expect(DemoFixtures(scenario: "types").connections.map(\.kind) == ConnectionKind.allCases)
  #expect(
    DemoFixtures(scenario: "failed").states.values.allSatisfy {
      if case .failed = $0 { return true }
      return false
    })
}

@MainActor @Test func demoMountLifecycleUsesOnlyMemory() async throws {
  let connection = Connection(kind: .smb, name: "Demo")
  let service = DemoMountService(delay: {})
  #expect(
    try await service.shares(host: "unused", user: "", password: "") == [
      "Demo", "Photos", "Documents",
    ])
  #expect(service.mounted(connection) == nil)
  await #expect(throws: ConnectionError.authentication) {
    try await service.test(connection, password: "error")
  }
  let url = try await service.mount(connection, password: "demo")
  #expect(service.mounted(connection)?.url == url)
  #expect(!FileManager.default.fileExists(atPath: url.path))
  try await service.unmount(url)
  #expect(service.mounted(connection) == nil)
}

@Test func demoTimeoutsUseTheSameDeviceAdviceAsRealFailures() {
  let demo = DemoFixtures(scenario: "failed")
  for connection in demo.connections {
    guard case .failed(let message) = demo.states[connection.id] else {
      Issue.record("Expected a failure fixture")
      continue
    }
    #expect(message == HumanError.remote(.posix(ETIMEDOUT), kind: connection.kind))
  }
}
