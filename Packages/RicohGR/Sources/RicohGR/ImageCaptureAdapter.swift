import Core
import Foundation
import ImageCaptureCore

@MainActor final class ImageCaptureAdapter: RicohCameraAdapter {
  private let device: any RicohDeviceAccess
  private var files = Set<UInt32>()
  private var transaction: UInt32 = 0

  convenience init(camera: ICCameraDevice, discovery: RicohDiscovery) {
    self.init(device: ImageCaptureDeviceAccess(camera: camera, discovery: discovery))
  }
  init(device: any RicohDeviceAccess) { self.device = device }
  var canDelete: Bool { device.canDelete }

  func open() async throws {
    try await open(until: .now.advanced(by: .seconds(RemoteTimeout.deviceRequest)))
  }
  func open(until deadline: ContinuousClock.Instant) async throws {
    try await device.open(until: deadline)
    guard device.supportsPTP else { throw RemoteError.unsupported }
    let model = try RicohPTP.deviceModel(await command(0x1001, deadline: deadline))
    guard CameraIdentity.isGRIV(model) else {
      throw NSError(
        domain: NSPOSIXErrorDomain, code: Int(ENOTSUP),
        userInfo: [NSLocalizedDescriptionKey: L("连接的相机未确认是 GR IV")])
    }
  }
  func close() async {
    await device.close()
    files.removeAll()
  }
  private func command(_ code: UInt16, parameters: [UInt32] = [], deadline: ContinuousClock.Instant)
    async throws -> Data
  {
    guard device.hasOpenSession else { throw RemoteError.notConnected }
    transaction &+= 1
    let (data, response) = try await device.command(
      RicohPTP.command(code, transaction: transaction, parameters: parameters), until: deadline)
    try RicohPTP.validateResponse(response)
    return data
  }
  func snapshot() async throws -> RicohSnapshot {
    try await snapshot(until: .now.advanced(by: .seconds(RemoteTimeout.deviceRequest)))
  }
  func snapshot(until deadline: ContinuousClock.Instant) async throws -> RicohSnapshot {
    _ = try RemoteTimeout.remaining(until: deadline)
    guard device.hasOpenSession else { throw RemoteError.notConnected }
    let ids = try RicohPTP.storageIDs(await command(0x1004, deadline: deadline))
    var storages: [RicohStorage] = []
    for id in ids {
      storages.append(
        try RicohPTP.storageInfo(
          await command(0x1005, parameters: [id], deadline: deadline), id: id))
    }
    var entries: [RicohEntry] = []
    var updatedFiles = Set<UInt32>()
    func children(_ folder: RicohCatalogItem, prefix: String = "") throws -> [(
      RicohCatalogItem, String
    )] {
      var result: [(RicohCatalogItem, String)] = []
      for item in folder.children {
        guard let name = item.name, !name.isEmpty, !name.contains("/"), name != ".", name != ".."
        else { throw RemoteError.protocolError }
        let path = prefix.isEmpty ? name : prefix + "/" + name
        result.append((item, path))
        if item.kind == .folder { result += try children(item, prefix: path) }
      }
      return result
    }
    files.removeAll()
    for root in device.contents {
      guard root.kind == .folder else { throw RemoteError.unsupported }
      let items = try children(root)
      guard !items.isEmpty else { continue }
      guard let probe = items.first(where: { $0.0.handle != 0 }) else {
        throw RemoteError.unsupported
      }
      let storageID = try RicohPTP.objectStorageID(
        await command(0x1008, parameters: [probe.0.handle], deadline: deadline))
      guard ids.contains(storageID) else { throw RemoteError.protocolError }
      for (item, path) in items {
        guard item.kind != .unsupported else { throw RemoteError.unsupported }
        if item.kind == .file {
          guard item.handle != 0, updatedFiles.insert(item.handle).inserted else {
            throw RemoteError.protocolError
          }
        }
        entries.append(
          RicohEntry(
            handle: item.handle, storageID: storageID, relativePath: path,
            isDirectory: item.kind == .folder, size: item.kind == .file ? item.size : 0,
            modified: item.modified))
      }
    }
    files = updatedFiles
    _ = try RemoteTimeout.remaining(until: deadline)
    return RicohSnapshot(storages: storages, entries: entries)
  }
  func read(handle: UInt32, offset: Int64, length: Int) async throws -> Data {
    guard device.hasOpenSession else { throw RemoteError.notConnected }
    guard files.contains(handle) else { throw RemoteError.posix(ENOENT) }
    do {
      guard let data = try await device.read(handle: handle, offset: offset, length: length) else {
        throw RemoteError.posix(EIO)
      }
      return data
    } catch { throw RicohErrorMapper.map(error) }
  }
  func delete(handles: [UInt32]) async throws {
    try await delete(
      handles: handles, until: .now.advanced(by: .seconds(RemoteTimeout.deviceRequest)))
  }
  func delete(handles: [UInt32], until deadline: ContinuousClock.Instant) async throws {
    guard device.hasOpenSession else { throw RemoteError.notConnected }
    guard device.canDelete else { throw RemoteError.posix(EACCES) }
    guard handles.allSatisfy({ files.contains($0) }) else { throw RemoteError.posix(ENOENT) }
    do { try await device.delete(handles: handles, until: deadline) } catch {
      throw RicohErrorMapper.map(error)
    }
    for handle in handles { files.remove(handle) }
  }
}
