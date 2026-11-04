import Foundation

struct RicohCatalogItem: Sendable {
  enum Kind: Sendable { case file, folder, unsupported }
  let handle: UInt32
  let name: String?
  let kind: Kind
  var size: Int64 = 0
  var modified: Date = Date(timeIntervalSince1970: 0)
  var children: [RicohCatalogItem] = []
}

@MainActor protocol RicohDeviceAccess: AnyObject {
  var hasOpenSession: Bool { get }
  var canDelete: Bool { get }
  var supportsPTP: Bool { get }
  var contents: [RicohCatalogItem] { get }
  func open(until deadline: ContinuousClock.Instant) async throws
  func close() async
  func command(_ bytes: Data, until deadline: ContinuousClock.Instant) async throws -> (Data, Data)
  func read(handle: UInt32, offset: Int64, length: Int) async throws -> Data?
  func delete(handles: [UInt32], until deadline: ContinuousClock.Instant) async throws
}
