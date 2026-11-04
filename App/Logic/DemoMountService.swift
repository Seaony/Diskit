import Core
import Foundation

@MainActor final class DemoMountService: SMBServing {
  private var mounts: [UUID: MountedShare]
  private let delay: @Sendable () async throws -> Void

  init(
    states: [UUID: ConnectionState] = [:],
    delay: @escaping @Sendable () async throws -> Void = {
      try await Task.sleep(for: .seconds(2))
    }
  ) {
    mounts = states.compactMapValues {
      if case .mounted(let mount) = $0 { return mount }
      return nil
    }
    self.delay = delay
  }

  func shares(host: String, user: String, password: String) async throws -> [String] {
    try await delay()
    return ["Demo", "Photos", "Documents"]
  }
  func test(_ connection: Connection, password: String) async throws {
    try await delay()
    if password == "error" { throw ConnectionError.authentication }
  }
  func mount(_ connection: Connection, password: String) async throws -> URL {
    try await test(connection, password: password)
    let mount = MountedShare(
      url: URL(filePath: "/tmp/KayoiDemo/\(connection.id)"), availableBytes: 120_000_000_000)
    mounts[connection.id] = mount
    return mount.url
  }
  func unmount(_ url: URL) async throws {
    try await delay()
    mounts = mounts.filter { $0.value.url != url }
  }
  func mounted(_ connection: Connection) -> MountedShare? { mounts[connection.id] }
}
