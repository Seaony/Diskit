import Core
import Foundation
import ImageCaptureCore

@MainActor private final class CameraCall<Value: Sendable> {
  private var continuation: CheckedContinuation<Value, Error>?
  private var timer: Task<Void, Never>?
  func run(seconds: Double, _ start: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void)
    async throws -> Value
  {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        timer = Task { @MainActor in
          do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
          self.finish(.failure(RemoteError.posix(ETIMEDOUT)))
        }
        start { result in Task { @MainActor in self.finish(result) } }
      }
    } onCancel: {
      Task { @MainActor in self.finish(.failure(CancellationError())) }
    }
  }
  private func finish(_ result: Result<Value, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    timer?.cancel()
    timer = nil
    continuation.resume(with: result)
  }
}

@MainActor
final class ImageCaptureAdapter: NSObject, RicohCameraAdapter,
  @preconcurrency ICCameraDeviceDelegate
{
  private let camera: ICCameraDevice
  private let discovery: RicohDiscovery
  private var files: [UInt32: ICCameraFile] = [:]
  private var ready: (@Sendable (Result<Void, Error>) -> Void)?
  private var available = true
  private var transaction: UInt32 = 0
  init(camera: ICCameraDevice, discovery: RicohDiscovery) {
    self.camera = camera
    self.discovery = discovery
    super.init()
  }

  func open() async throws {
    guard available else { throw RemoteError.notConnected }
    camera.delegate = self
    try await CameraCall<Void>().run(seconds: 15) { complete in
      camera.requestOpenSession(options: nil) { error in
        if let error { complete(.failure(error)) } else { complete(.success(())) }
      }
    }
    if camera.contentCatalogPercentCompleted < 100 {
      try await CameraCall<Void>().run(seconds: 15) { complete in ready = complete }
    }
    guard camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue)
    else { throw RemoteError.unsupported }
    let model = try RicohPTP.deviceModel(await command(0x1001))
    guard model.uppercased().contains("GR IV") else {
      throw NSError(
        domain: NSPOSIXErrorDomain, code: Int(ENOTSUP),
        userInfo: [NSLocalizedDescriptionKey: L("连接的相机未确认是 GR IV")])
    }
  }
  func close() async {
    ready?(.failure(RemoteError.notConnected))
    ready = nil
    if camera.hasOpenSession {
      _ = try? await CameraCall<Void>().run(seconds: 15) { complete in
        camera.requestCloseSession(options: nil) { error in
          if let error { complete(.failure(error)) } else { complete(.success(())) }
        }
      }
    }
    camera.delegate = nil
    files.removeAll()
    discovery.stop()
  }
  private func command(_ code: UInt16, parameters: [UInt32] = []) async throws -> Data {
    guard available, camera.hasOpenSession else { throw RemoteError.notConnected }
    transaction &+= 1
    let bytes = RicohPTP.command(code, transaction: transaction, parameters: parameters)
    return try await CameraCall<Data>().run(seconds: 15) { complete in
      camera.requestSendPTPCommand(bytes, outData: nil) { data, response, error in
        if let error {
          complete(.failure(error))
          return
        }
        do {
          try RicohPTP.validateResponse(response)
          complete(.success(data))
        } catch { complete(.failure(error)) }
      }
    }
  }
  func snapshot() async throws -> RicohSnapshot {
    guard available, camera.hasOpenSession else { throw RemoteError.notConnected }
    let ids = try RicohPTP.storageIDs(await command(0x1004))
    var storages: [RicohStorage] = []
    for id in ids {
      storages.append(try RicohPTP.storageInfo(await command(0x1005, parameters: [id]), id: id))
    }
    var entries: [RicohEntry] = []
    var updatedFiles: [UInt32: ICCameraFile] = [:]
    func children(_ folder: ICCameraFolder, prefix: String = "") throws -> [(ICCameraItem, String)]
    {
      var result: [(ICCameraItem, String)] = []
      for item in folder.contents ?? [] {
        guard let name = item.name, !name.isEmpty, !name.contains("/"), name != ".", name != ".."
        else { throw RemoteError.protocolError }
        let path = prefix.isEmpty ? name : prefix + "/" + name
        result.append((item, path))
        if let folder = item as? ICCameraFolder { result += try children(folder, prefix: path) }
      }
      return result
    }
    // ICC 保证 contents 的每个顶层项对应一个存储区；只补查其真实子项的 StorageID。
    for root in camera.contents ?? [] {
      guard let folder = root as? ICCameraFolder else { throw RemoteError.unsupported }
      let items = try children(folder)
      guard !items.isEmpty else { continue }
      guard let probe = items.first(where: { $0.0.ptpObjectHandle != 0 }) else {
        throw RemoteError.unsupported
      }
      let storageID = try RicohPTP.objectStorageID(
        await command(0x1008, parameters: [probe.0.ptpObjectHandle]))
      guard ids.contains(storageID) else { throw RemoteError.protocolError }
      for (item, path) in items {
        let file = item as? ICCameraFile
        if let file { updatedFiles[item.ptpObjectHandle] = file }
        entries.append(
          RicohEntry(
            handle: item.ptpObjectHandle, storageID: storageID, relativePath: path,
            isDirectory: file == nil, size: file?.fileSize ?? 0,
            modified: item.modificationDate ?? item.creationDate ?? Date(timeIntervalSince1970: 0)))
      }
    }
    files = updatedFiles
    return RicohSnapshot(storages: storages, entries: entries)
  }
  func read(handle: UInt32, offset: Int64, length: Int) async throws -> Data {
    guard available, camera.hasOpenSession else { throw RemoteError.notConnected }
    guard let file = files[handle] else { throw RemoteError.posix(ENOENT) }
    return try await CameraCall<Data>().run(seconds: 60) { complete in
      file.requestReadData(atOffset: offset, length: Int64(length)) { data, error in
        if error != nil {
          complete(.failure(RemoteError.posix(EIO)))
        } else if let data {
          complete(.success(data))
        } else {
          complete(.failure(RemoteError.posix(EIO)))
        }
      }
    }
  }
  func delete(handles: [UInt32]) async throws {
    guard available, camera.hasOpenSession else { throw RemoteError.notConnected }
    guard !camera.isLocked,
      camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue)
    else { throw RemoteError.posix(EACCES) }
    let selected = try handles.map { handle in
      guard let file = files[handle] else { throw RemoteError.posix(ENOENT) }
      return file
    }
    try await CameraCall<Void>().run(seconds: 15) { complete in
      camera.requestDeleteFiles(
        selected, deleteFailed: { _ in complete(.failure(RemoteError.posix(EACCES))) }
      ) { _, error in
        if error != nil {
          complete(.failure(RemoteError.posix(EACCES)))
        } else {
          complete(.success(()))
        }
      }
    }
    for handle in handles { files.removeValue(forKey: handle) }
  }
  func didRemove(_ device: ICDevice) {
    available = false
    ready?(.failure(RemoteError.notConnected))
    ready = nil
  }
  func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
  func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
  func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
    ready?(.success(()))
    ready = nil
  }
  func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
  func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
  func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
  func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
  func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
  func cameraDevice(
    _ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem,
    error: Error?
  ) {}
  func cameraDevice(
    _ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?,
    for item: ICCameraItem, error: Error?
  ) {}
  func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
  func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
}
