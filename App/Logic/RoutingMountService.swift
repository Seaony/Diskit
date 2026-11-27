import Core
import Foundation

@MainActor final class RoutingMountService: SMBServing {
  let system: any SMBServing
  let fileSystem: FileSystemMountService

  init(system: any SMBServing, fileSystem: FileSystemMountService) {
    self.system = system
    self.fileSystem = fileSystem
  }

  private func service(_ connection: Connection) throws -> any SMBServing {
    if connection.kind.usesSystemMount { return system }
    if connection.kind.fileSystemScheme != nil { return fileSystem }
    throw RemoteError.unsupported
  }

  func shares(host: String, user: String, password: String) async throws -> [String] {
    try await system.shares(host: host, user: user, password: password)
  }

  func test(_ connection: Connection, password: String) async throws {
    try await service(connection).test(connection, password: password)
  }

  func mount(_ connection: Connection, password: String) async throws -> URL {
    let service = try service(connection)
    guard connection.kind == .androidMTP else {
      return try await service.mount(connection, password: password)
    }
    return try await AndroidFileTransfer.connecting {
      try await service.mount(connection, password: password)
    }
  }

  func unmount(_ url: URL) async throws {
    if fileSystem.isFileSystemVolume(url) { try await fileSystem.unmount(url) }
    else { try await system.unmount(url) }
  }

  func mounted(_ connection: Connection) -> MountedShare? {
    (try? service(connection))?.mounted(connection)
  }

  func refreshMounted(_ connection: Connection) async -> MountedShare? {
    guard let service = try? service(connection) else { return nil }
    return await service.refreshMounted(connection)
  }
}
