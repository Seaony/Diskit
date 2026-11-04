import Core
import Foundation

public struct CameraUSBDevice: Identifiable, Sendable, Equatable {
  public let id: String
  public let serial: String
  public let name: String
  public let vendorID: Int
  public let productID: Int

  public init(id: String, serial: String, name: String, vendorID: Int, productID: Int) {
    self.id = id
    self.serial = serial
    self.name = name
    self.vendorID = vendorID
    self.productID = productID
  }
}

public struct CameraUSBStorage: Sendable, Equatable {
  public let id: String
  public let name: String
  public let total: Int64?
  public let available: Int64?

  public init(id: String, name: String, total: Int64? = nil, available: Int64? = nil) {
    self.id = id
    self.name = name
    self.total = total
    self.available = available
  }
}

public struct CameraUSBEntry: Sendable, Equatable {
  public let storageID: String
  public let relativePath: String
  public let isDirectory: Bool
  public let size: Int64
  public let modified: Date
  public let fileHandle: UInt32?

  public init(
    storageID: String,
    relativePath: String,
    isDirectory: Bool,
    size: Int64,
    modified: Date,
    fileHandle: UInt32? = nil
  ) {
    self.storageID = storageID
    self.relativePath = relativePath
    self.isDirectory = isDirectory
    self.size = size
    self.modified = modified
    self.fileHandle = fileHandle
  }
}

public struct CameraUSBSnapshot: Sendable, Equatable {
  public let storages: [CameraUSBStorage]
  public let entries: [CameraUSBEntry]

  public init(storages: [CameraUSBStorage], entries: [CameraUSBEntry]) {
    self.storages = storages
    self.entries = entries
  }
}

@MainActor
protocol CameraUSBAccess: AnyObject, Sendable {
  var canDelete: Bool { get }
  func open() async throws
  func close() async
  func snapshot() async throws -> CameraUSBSnapshot
  func read(handle: UInt32, offset: Int64, length: Int) async throws -> Data
  func delete(handles: [UInt32]) async throws
}
