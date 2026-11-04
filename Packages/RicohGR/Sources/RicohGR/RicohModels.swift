import Core
import Foundation

public enum RicohStorageKind: Sendable, Equatable {
  case internalStorage, microSD
  var name: String { self == .internalStorage ? "内置存储" : "microSD" }
}

public struct RicohStorage: Sendable, Equatable {
  public let id: UInt32
  public let kind: RicohStorageKind
  public let total: Int64
  public let free: Int64
  public init(id: UInt32, kind: RicohStorageKind, total: Int64, free: Int64) {
    self.id = id
    self.kind = kind
    self.total = total
    self.free = free
  }
}

public struct RicohEntry: Sendable, Equatable {
  public let handle: UInt32
  public let storageID: UInt32
  public let relativePath: String
  public let isDirectory: Bool
  public let size: Int64
  public let modified: Date
  public init(
    handle: UInt32, storageID: UInt32, relativePath: String, isDirectory: Bool, size: Int64,
    modified: Date
  ) {
    self.handle = handle
    self.storageID = storageID
    self.relativePath = relativePath
    self.isDirectory = isDirectory
    self.size = size
    self.modified = modified
  }
}

public struct RicohSnapshot: Sendable, Equatable {
  public let storages: [RicohStorage]
  public let entries: [RicohEntry]
  public init(storages: [RicohStorage], entries: [RicohEntry]) {
    self.storages = storages
    self.entries = entries
  }
}

@MainActor public protocol RicohCameraAdapter: AnyObject, Sendable {
  var canDelete: Bool { get }
  func open() async throws
  func close() async
  func snapshot() async throws -> RicohSnapshot
  func read(handle: UInt32, offset: Int64, length: Int) async throws -> Data
  func delete(handles: [UInt32]) async throws
  func open(until deadline: ContinuousClock.Instant) async throws
  func snapshot(until deadline: ContinuousClock.Instant) async throws -> RicohSnapshot
  func delete(handles: [UInt32], until deadline: ContinuousClock.Instant) async throws
}

extension RicohCameraAdapter {
  public var canDelete: Bool { true }
  public func open(until deadline: ContinuousClock.Instant) async throws {
    _ = try RemoteTimeout.remaining(until: deadline)
    try await open()
    _ = try RemoteTimeout.remaining(until: deadline)
  }
  public func snapshot(until deadline: ContinuousClock.Instant) async throws -> RicohSnapshot {
    _ = try RemoteTimeout.remaining(until: deadline)
    let result = try await snapshot()
    _ = try RemoteTimeout.remaining(until: deadline)
    return result
  }
  public func delete(handles: [UInt32], until deadline: ContinuousClock.Instant) async throws {
    _ = try RemoteTimeout.remaining(until: deadline)
    try await delete(handles: handles)
    _ = try RemoteTimeout.remaining(until: deadline)
  }
}
