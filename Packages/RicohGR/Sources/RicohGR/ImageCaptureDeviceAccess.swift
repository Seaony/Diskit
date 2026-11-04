import Core
import Foundation
import ImageCaptureCore

@MainActor
final class ImageCaptureDeviceAccess: RicohDeviceAccess {
  private let camera: any RicohCameraHardware
  private var files: [UInt32: any RicohHardwareFile] = [:]
  private var ready: (@Sendable (Result<Void, Error>) -> Void)?
  private var available = true
  convenience init(camera: ICCameraDevice, discovery: RicohDiscovery) {
    self.init(hardware: ICRicohCameraHardware(camera: camera, discovery: discovery))
  }
  init(hardware: any RicohCameraHardware) {
    camera = hardware
    camera.removed = { [weak self] in self?.didRemove() }
    camera.catalogReady = { [weak self] in self?.didBecomeReady() }
  }
  var hasOpenSession: Bool { available && camera.hasOpenSession }
  var canDelete: Bool {
    !camera.isLocked
      && camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue)
  }
  var supportsPTP: Bool {
    camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue)
  }
  var contents: [RicohCatalogItem] {
    files.removeAll()
    return (camera.contents ?? []).map(catalogItem)
  }
  private func catalogItem(_ item: any RicohHardwareItem) -> RicohCatalogItem {
    let file = item.file
    let children = item.children
    if let file { files[item.handle] = file }
    return RicohCatalogItem(
      handle: item.handle, name: item.name,
      kind: file != nil ? .file : children != nil ? .folder : .unsupported,
      size: file?.size ?? 0,
      modified: item.modified ?? item.created ?? Date(timeIntervalSince1970: 0),
      children: (children ?? []).map(catalogItem))
  }
  func open(until deadline: ContinuousClock.Instant) async throws {
    guard available else { throw RemoteError.notConnected }
    camera.start()
    try await CameraCall<Void>().run(until: deadline) { complete in
      camera.open { error in
        complete(error.map(Result.failure) ?? .success(()))
      }
    }
    if camera.catalogPercent < 100 {
      try await CameraCall<Void>().run(until: deadline) { complete in ready = complete }
    }
  }
  func close() async {
    ready?(.failure(RemoteError.notConnected))
    ready = nil
    if camera.hasOpenSession {
      do {
        try await CameraCall<Void>().run(seconds: RemoteTimeout.deviceRequest) { complete in
          camera.close { error in
            complete(error.map(Result.failure) ?? .success(()))
          }
        }
      } catch {
        PackageDiagnostics.failure(error, category: .ricohGR, operation: .disconnect)
      }
    }

    files.removeAll()
    camera.stop()
  }
  func command(_ bytes: Data, until deadline: ContinuousClock.Instant) async throws -> (Data, Data)
  {
    try await CameraCall<(Data, Data)>().run(until: deadline) { complete in
      camera.command(bytes) { data, response, error in
        complete(error.map(Result.failure) ?? .success((data, response)))
      }
    }
  }
  func read(handle: UInt32, offset: Int64, length: Int) async throws -> Data? {
    guard let file = files[handle] else { throw RemoteError.posix(ENOENT) }
    return try await CameraCall<Data?>().run(seconds: RemoteTimeout.transferIdle) { complete in
      file.read(offset: offset, length: Int64(length)) { data, error in
        complete(error.map(Result.failure) ?? .success(data))
      }
    }
  }
  func delete(handles: [UInt32], until deadline: ContinuousClock.Instant) async throws {
    let selected = try handles.map { handle in
      guard let file = files[handle] else { throw RemoteError.posix(ENOENT) }
      return file
    }
    try await CameraCall<Void>().run(until: deadline) { complete in
      do {
        try camera.delete(selected, failed: { complete(.failure(RemoteError.posix(EACCES))) }) {
          error in
          complete(error.map(Result.failure) ?? .success(()))
        }
      } catch { complete(.failure(error)) }
    }
    for handle in handles { files.removeValue(forKey: handle) }
  }
  func didRemove() {
    available = false
    ready?(.failure(RemoteError.notConnected))
    ready = nil
  }
  func didBecomeReady() {
    ready?(.success(()))
    ready = nil
  }
}
