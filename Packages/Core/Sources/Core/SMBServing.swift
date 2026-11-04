import Foundation

@MainActor public protocol SMBServing: AnyObject {
  func shares(host: String, user: String, password: String) async throws -> [String]
  func test(_ connection: Connection, password: String) async throws
  func mount(_ connection: Connection, password: String) async throws -> URL
  func unmount(_ url: URL) async throws
  func mounted(_ connection: Connection) -> MountedShare?
  func refreshMounted(_ connection: Connection) async -> MountedShare?
}

extension SMBServing {
  public func refreshMounted(_ connection: Connection) async -> MountedShare? {
    mounted(connection)
  }
}
