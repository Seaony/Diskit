import Core
import Foundation

@MainActor
final class NativeCameraSession: CameraDeviceSession {
  private let camera: any CameraHardware
  private var files: [UInt32: any CameraHardwareItem] = [:]
  private var ready: (@Sendable (Result<Void, Error>) -> Void)?
  private(set) var available = true
  var isOpen: Bool { camera.isOpen }
  var catalogReady: Bool { camera.catalogProgress >= 100 }
  var canDelete: Bool { !camera.locked && camera.deleteSupported }
  init(camera: any CameraHardware) {
    self.camera = camera
    camera.removed = { [weak self] in self?.didRemove() }
  }
  func open(until deadline: ContinuousClock.Instant) async throws {
    camera.start()
    try await CameraCall<Void>().run(until: deadline) { complete in
      camera.open { error in
        complete(error.map { .failure($0) } ?? .success(()))
      }
    }
  }
  func waitForCatalog(until deadline: ContinuousClock.Instant) async throws {
    try await CameraCall<Void>().run(until: deadline) { complete in
      ready = complete
      camera.ready = { [weak self] in self?.didBecomeReady() }
    }
  }
  func close() async {
    ready?(.failure(RemoteError.failed(EIO, L("相机目录还没加载完，连接就被关闭了"))))
    ready = nil
    if camera.isOpen {
      do {
        try await CameraCall<Void>().run(seconds: RemoteTimeout.deviceRequest) { complete in
          camera.close { error in
            complete(error.map { .failure($0) } ?? .success(()))
          }
        }
      } catch {
        PackageDiagnostics.failure(error, category: .cameraUSB, operation: .disconnect)
      }
    }
    files.removeAll()
    camera.stop()
  }
  func catalog() -> [CameraCatalogItem] {
    files.removeAll()
    func convert(_ item: any CameraHardwareItem) -> CameraCatalogItem {
      let size = item.size
      let children = item.children
      if size != nil { files[item.handle] = item }
      return CameraCatalogItem(
        kind: size != nil ? .file : item.isFolder ? .folder : .unsupported,
        name: item.name, handle: item.handle, size: size ?? 0,
        modified: item.modified ?? item.created ?? Date(timeIntervalSince1970: 0),
        children: (children ?? []).map(convert))
    }
    return (camera.contents ?? []).map(convert)
  }
  func read(handle: UInt32, offset: Int64, length: Int) async throws -> Data {
    guard let file = files[handle] else { throw RemoteError.posix(ENOENT) }
    return try await CameraCall<Data>().run(seconds: RemoteTimeout.transferIdle) { complete in
      file.read(offset: offset, length: length) { data, error in
        complete(
          error.map { .failure($0) } ?? data.map { .success($0) }
            ?? .failure(RemoteError.failed(EIO, L("相机没有返回数据，也没有报错"))))
      }
    }
  }
  func delete(handles: [UInt32], until deadline: ContinuousClock.Instant) async throws {
    let selected = try handles.map { handle in
      guard let file = files[handle] else { throw RemoteError.posix(ENOENT) }
      return file
    }
    try await CameraCall<Void>().run(until: deadline) { complete in
      camera.delete(selected, failed: { complete(.failure(RemoteError.posix(EACCES))) }) { error in
        complete(error.map { .failure($0) } ?? .success(()))
      }
    }
    for handle in handles { files.removeValue(forKey: handle) }
  }
  func didRemove() {
    available = false
    ready?(.failure(RemoteError.failed(EIO, L("相机在加载目录时被拔出或断开"))))
    ready = nil
  }
  func didBecomeReady() {
    ready?(.success(()))
    ready = nil
  }
}
