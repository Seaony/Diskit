import Core
import Foundation
import ImageCaptureCore

@MainActor
private final class CameraCall<Value: Sendable> {
  private var continuation: CheckedContinuation<Value, Error>?
  private var timer: Task<Void, Never>?

  func run(seconds: Double, _ start: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void)
    async throws -> Value
  {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        timer = Task { @MainActor in
          do {
            try await Task.sleep(for: .seconds(seconds))
          } catch {
            return
          }
          self.finish(.failure(RemoteError.posix(ETIMEDOUT)))
        }
        start { result in
          Task { @MainActor in
            self.finish(result)
          }
        }
      }
    } onCancel: {
      Task { @MainActor in
        self.finish(.failure(CancellationError()))
      }
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
final class ImageCaptureAccess: NSObject, CameraUSBAccess,
  @preconcurrency ICCameraDeviceDelegate
{
  private let camera: ICCameraDevice
  private let discovery: CameraUSBDiscovery
  private var files: [UInt32: ICCameraFile] = [:]
  private var ready: (@Sendable (Result<Void, Error>) -> Void)?
  private var available = true

  var canDelete: Bool {
    !camera.isLocked
      && camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue)
  }

  init(camera: ICCameraDevice, discovery: CameraUSBDiscovery) {
    self.camera = camera
    self.discovery = discovery
    super.init()
  }

  func open() async throws {
    guard available else { throw RemoteError.posix(EIO) }
    camera.delegate = self
    do {
      try await CameraCall<Void>().run(seconds: 15) { complete in
        camera.requestOpenSession(options: nil) { error in
          if let error {
            complete(.failure(error))
          } else {
            complete(.success(()))
          }
        }
      }
      if camera.contentCatalogPercentCompleted < 100 {
        try await CameraCall<Void>().run(seconds: 15) { complete in
          ready = complete
        }
      }
    } catch {
      camera.delegate = nil
      throw CameraUSBErrorMapper.map(error)
    }
  }

  func close() async {
    ready?(.failure(RemoteError.posix(EIO)))
    ready = nil
    if camera.hasOpenSession {
      _ = try? await CameraCall<Void>().run(seconds: 15) { complete in
        camera.requestCloseSession(options: nil) { error in
          if let error {
            complete(.failure(error))
          } else {
            complete(.success(()))
          }
        }
      }
    }
    camera.delegate = nil
    files.removeAll()
    discovery.stop()
  }

  func snapshot() async throws -> CameraUSBSnapshot {
    guard available, camera.hasOpenSession else { throw RemoteError.posix(EIO) }

    var entries: [CameraUSBEntry] = []
    var storedFiles: [UInt32: ICCameraFile] = [:]
    var storages: [CameraUSBStorage] = []

    for (index, item) in (camera.contents ?? []).enumerated() {
      guard let folder = item as? ICCameraFolder else { throw RemoteError.unsupported }
      let storageName = try storageName(folder.name, index: index)
      let storageID =
        folder.ptpObjectHandle == 0
        ? "storage-\(index)" : String(folder.ptpObjectHandle)
      storages.append(CameraUSBStorage(id: storageID, name: storageName))
      try appendContents(
        of: folder, storageID: storageID, prefix: "", entries: &entries, files: &storedFiles)
    }

    files = storedFiles
    return CameraUSBSnapshot(storages: storages, entries: entries)
  }

  func read(handle: UInt32, offset: Int64, length: Int) async throws -> Data {
    guard available, camera.hasOpenSession else { throw RemoteError.posix(EIO) }
    guard let file = files[handle] else { throw RemoteError.posix(ENOENT) }
    do {
      return try await CameraCall<Data>().run(seconds: 60) { complete in
        file.requestReadData(atOffset: offset, length: Int64(length)) { data, error in
          if let error {
            complete(.failure(error))
          } else if let data {
            complete(.success(data))
          } else {
            complete(.failure(RemoteError.posix(EIO)))
          }
        }
      }
    } catch {
      throw CameraUSBErrorMapper.map(error)
    }
  }

  func delete(handles: [UInt32]) async throws {
    guard available, camera.hasOpenSession else { throw RemoteError.posix(EIO) }
    guard canDelete else { throw RemoteError.posix(EACCES) }
    let selected = try handles.map { handle in
      guard let file = files[handle] else { throw RemoteError.posix(ENOENT) }
      return file
    }
    do {
      try await CameraCall<Void>().run(seconds: 15) { complete in
        camera.requestDeleteFiles(
          selected,
          deleteFailed: { _ in complete(.failure(RemoteError.posix(EACCES))) }
        ) { _, error in
          if let error {
            complete(.failure(error))
          } else {
            complete(.success(()))
          }
        }
      }
    } catch {
      throw CameraUSBErrorMapper.map(error)
    }
    for handle in handles {
      files.removeValue(forKey: handle)
    }
  }

  func didRemove(_ device: ICDevice) {
    available = false
    ready?(.failure(RemoteError.posix(EIO)))
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

  private func storageName(_ value: String?, index: Int) throws -> String {
    let name = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let result = name.isEmpty ? "存储 \(index + 1)" : name
    guard !result.contains("/"), result != ".", result != "..", !result.contains("\0") else {
      throw RemoteError.protocolError
    }
    return result
  }

  private func appendContents(
    of folder: ICCameraFolder,
    storageID: String,
    prefix: String,
    entries: inout [CameraUSBEntry],
    files: inout [UInt32: ICCameraFile]
  ) throws {
    for item in folder.contents ?? [] {
      guard let name = item.name, !name.isEmpty, !name.contains("/"), name != ".", name != ".."
      else {
        throw RemoteError.protocolError
      }
      let path = prefix.isEmpty ? name : prefix + "/" + name
      if let file = item as? ICCameraFile {
        guard file.ptpObjectHandle != 0, files[file.ptpObjectHandle] == nil else {
          throw RemoteError.protocolError
        }
        files[file.ptpObjectHandle] = file
        entries.append(
          CameraUSBEntry(
            storageID: storageID, relativePath: path, isDirectory: false,
            size: file.fileSize,
            modified: file.modificationDate ?? file.creationDate ?? Date(timeIntervalSince1970: 0),
            fileHandle: file.ptpObjectHandle))
      } else if let child = item as? ICCameraFolder {
        entries.append(
          CameraUSBEntry(
            storageID: storageID, relativePath: path, isDirectory: true, size: 0,
            modified: item.modificationDate ?? item.creationDate ?? Date(timeIntervalSince1970: 0)))
        try appendContents(
          of: child, storageID: storageID, prefix: path, entries: &entries, files: &files)
      } else {
        throw RemoteError.unsupported
      }
    }
  }
}
