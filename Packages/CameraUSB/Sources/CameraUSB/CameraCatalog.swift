import Core
import Foundation

struct CameraCatalogItem: Sendable {
  enum Kind: Sendable { case folder, file, unsupported }
  let kind: Kind
  let name: String?
  let handle: UInt32
  var size: Int64 = 0
  var modified: Date = Date(timeIntervalSince1970: 0)
  var children: [CameraCatalogItem] = []
}

enum CameraCatalog {
  static func snapshot(_ roots: [CameraCatalogItem]) throws -> CameraUSBSnapshot {
    var storages: [CameraUSBStorage] = []
    var entries: [CameraUSBEntry] = []
    var handles = Set<UInt32>()
    var paths = Set<String>()
    func visit(_ item: CameraCatalogItem, storage: String, prefix: String) throws {
      guard let name = item.name, !name.isEmpty, name != ".", name != "..",
        !name.contains("/"), !name.contains("\0"), item.size >= 0
      else { throw RemoteError.protocolError }
      let path = prefix.isEmpty ? name : prefix + "/" + name
      guard paths.insert(storage + "/" + path).inserted else { throw RemoteError.protocolError }
      switch item.kind {
      case .unsupported: throw RemoteError.unsupported
      case .file:
        guard item.handle != 0, handles.insert(item.handle).inserted else {
          throw RemoteError.protocolError
        }
        entries.append(
          CameraUSBEntry(
            storageID: storage, relativePath: path,
            isDirectory: false, size: item.size, modified: item.modified, fileHandle: item.handle))
      case .folder:
        entries.append(
          CameraUSBEntry(
            storageID: storage, relativePath: path,
            isDirectory: true, size: 0, modified: item.modified))
        for child in item.children { try visit(child, storage: storage, prefix: path) }
      }
    }
    for (index, root) in roots.enumerated() {
      guard root.kind == .folder else { throw RemoteError.unsupported }
      let trimmed = root.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let name = trimmed.isEmpty ? LF("存储 %lld", Int64(index + 1)) : trimmed
      guard name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
        throw RemoteError.protocolError
      }
      let id = root.handle == 0 ? "storage-\(index)" : String(root.handle)
      guard !storages.contains(where: { $0.id == id || $0.name == name }) else {
        throw RemoteError.protocolError
      }
      storages.append(CameraUSBStorage(id: id, name: name))
      for child in root.children { try visit(child, storage: id, prefix: "") }
    }
    return CameraUSBSnapshot(storages: storages, entries: entries)
  }
}

@MainActor protocol CameraDeviceSession: AnyObject {
  var available: Bool { get }
  var isOpen: Bool { get }
  var catalogReady: Bool { get }
  var canDelete: Bool { get }
  func open(until: ContinuousClock.Instant) async throws
  func waitForCatalog(until: ContinuousClock.Instant) async throws
  func close() async
  func catalog() -> [CameraCatalogItem]
  func read(handle: UInt32, offset: Int64, length: Int) async throws -> Data
  func delete(handles: [UInt32], until: ContinuousClock.Instant) async throws
}
