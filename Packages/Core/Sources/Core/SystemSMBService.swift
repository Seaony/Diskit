import AppKit
import CoreNative
import Darwin
import Foundation
import NetFS
import OSLog

@MainActor public final class SystemSMBService: SMBServing {
  private let location: any StorageLocation
  private struct CapacityKey: Hashable, Sendable {
    let path: URL
    let filesystemID: Data
  }
  private var availableCapacity: [CapacityKey: Int64] = [:]
  private var refreshingCapacity = Set<CapacityKey>()
  struct MountEntry: Sendable {
    let type: String
    let source: String
    let path: URL
    let filesystemID: Data
    var availableBytes: Int64?
  }
  struct Operations {
    var mount: @MainActor (URL, String, String, Bool, URL?) async throws -> URL = {
      try await MountRequest().run(url: $0, user: $1, password: $2, guest: $3, mountPoint: $4)
    }
    var unmount: @MainActor (URL) async throws -> Void = { try await UnmountRequest().run($0) }
    var entries: @MainActor () -> [MountEntry] = { NativeMountTable.entries() }
    var capacity: @Sendable (URL) -> MountEntry? = { NativeMountTable.capacity($0) }
    var shares: @Sendable (String, String) throws -> (String, Int32) = { server, password in
      var output = [CChar](repeating: 0, count: 1_048_576)
      var status: Int32 = 0
      let result = diskit_smb_shares(
        server, password, &output, output.count, &status, RemoteTimeout.deviceRequest)
      guard result == 0 else { throw ConnectionError.status(result) }
      return (
        String(decoding: output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
        status
      )
    }
  }
  private let operations: Operations
  public convenience init(location: any StorageLocation = LocalStorageLocation()) {
    self.init(location: location, operations: Operations())
  }
  init(location: any StorageLocation, operations: Operations) {
    self.location = location
    self.operations = operations
  }
  public func test(_ connection: Connection, password: String) async throws {
    let directory = location.connectionTestDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // 只删除空挂载点，推出失败时绝不能递归删除远端内容。
    defer { _ = rmdir(directory.path) }
    let url = try SystemMountAddress.url(for: connection)
    let mounted = try await operations.mount(
      url, connection.params["username"] ?? "", password, connection.params["guest"] == "true",
      directory)
    guard mounted.standardizedFileURL == directory.standardizedFileURL else {
      throw ConnectionError.system(EIO)
    }
    try await unmount(mounted)
  }
  public func shares(host: String, user: String, password: String) async throws -> [String] {
    let url = try SMBAddress.url(host: host, user: user)
    guard !password.contains("\n"), !password.contains("\r"), !password.contains("\0") else {
      throw ConnectionError.authentication
    }
    let server = String(url.absoluteString.dropFirst(4))
    let shares = operations.shares
    return try await Task.detached {
      do {
        let (output, status) = try shares(server, password)
        return try SMBAddress.parseShares(output, exitStatus: status)
      } catch {
        PackageDiagnostics.failure(error, category: .core, operation: .discover)
        throw error
      }
    }.value
  }
  public func mount(_ connection: Connection, password: String) async throws -> URL {
    let url = try SystemMountAddress.url(for: connection)
    return try await operations.mount(
      url, connection.params["username"] ?? "", password, connection.params["guest"] == "true", nil)
  }
  public func unmount(_ url: URL) async throws {
    try await operations.unmount(url)
  }

  public func refreshMounted(_ connection: Connection) async -> MountedShare? {
    guard let current = mounted(connection), let key = capacityKey(mount: current)
    else { return nil }
    guard refreshingCapacity.insert(key).inserted else { return current }
    let capacity = operations.capacity
    let result = await MountCapacityRequest().run(
      read: { Self.readAvailableCapacity(connection, key: key, read: capacity) },
      completed: { [weak self] value in
        guard let self else { return }
        self.refreshingCapacity.remove(key)
        guard let latest = self.mounted(connection),
          self.capacityKey(mount: latest) == key
        else {
          self.availableCapacity.removeValue(forKey: key)
          return
        }
        self.availableCapacity[key] = value
      })
    if result == nil, refreshingCapacity.contains(key) {
      availableCapacity.removeValue(forKey: key)
    }
    return mounted(connection)
  }

  private func capacityKey(mount: MountedShare) -> CapacityKey? {
    guard let filesystemID = mount.filesystemID else { return nil }
    return CapacityKey(path: mount.url, filesystemID: filesystemID)
  }

  private nonisolated static func readAvailableCapacity(
    _ connection: Connection, key: CapacityKey, read: @Sendable (URL) -> MountEntry?
  ) -> Int64? {
    guard let entry = read(key.path), entry.filesystemID == key.filesystemID,
      SystemMountAddress.matches(connection: connection, source: entry.source, type: entry.type)
    else { return nil }
    return entry.availableBytes
  }

  public func mounted(_ connection: Connection) -> MountedShare? {
    for entry in operations.entries() {
      guard
        SystemMountAddress.matches(connection: connection, source: entry.source, type: entry.type)
      else { continue }
      var mounted = MountedShare(url: entry.path)
      mounted.filesystemID = entry.filesystemID
      if let key = capacityKey(mount: mounted) {
        availableCapacity = availableCapacity.filter { $0.key.path != key.path || $0.key == key }
        mounted.availableBytes = availableCapacity[key]
      }
      return mounted
    }
    return nil
  }
}
