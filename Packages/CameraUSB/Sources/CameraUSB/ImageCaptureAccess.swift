import Core
import Foundation
import ImageCaptureCore

@MainActor final class ImageCaptureAccess: CameraUSBAccess {
  private let session: any CameraDeviceSession
  private var handles = Set<UInt32>()
  var canDelete: Bool { session.canDelete }

  init(session: any CameraDeviceSession) { self.session = session }
  convenience init(camera: ICCameraDevice, discovery: CameraUSBDiscovery) {
    self.init(
      session: NativeCameraSession(camera: ICCCameraHardware(camera: camera, discovery: discovery)))
  }
  func open() async throws {
    try await open(until: .now.advanced(by: .seconds(RemoteTimeout.deviceRequest)))
  }
  func open(until deadline: ContinuousClock.Instant) async throws {
    guard session.available else { throw RemoteError.posix(EIO) }
    do {
      try await session.open(until: deadline)
      if !session.catalogReady { try await session.waitForCatalog(until: deadline) }
    } catch { throw CameraUSBErrorMapper.map(error) }
  }
  func close() async {
    handles.removeAll()
    await session.close()
  }
  func snapshot() async throws -> CameraUSBSnapshot {
    try await snapshot(until: .now.advanced(by: .seconds(RemoteTimeout.deviceRequest)))
  }
  func snapshot(until deadline: ContinuousClock.Instant) async throws -> CameraUSBSnapshot {
    _ = try RemoteTimeout.remaining(until: deadline)
    guard session.available, session.isOpen else { throw RemoteError.posix(EIO) }
    handles.removeAll()
    let result = try CameraCatalog.snapshot(session.catalog())
    handles = Set(result.entries.compactMap(\.fileHandle))
    _ = try RemoteTimeout.remaining(until: deadline)
    return result
  }
  func read(handle: UInt32, offset: Int64, length: Int) async throws -> Data {
    guard session.available, session.isOpen else { throw RemoteError.posix(EIO) }
    guard handles.contains(handle) else { throw RemoteError.posix(ENOENT) }
    do { return try await session.read(handle: handle, offset: offset, length: length) } catch {
      throw CameraUSBErrorMapper.map(error)
    }
  }
  func delete(handles: [UInt32]) async throws {
    try await delete(
      handles: handles, until: .now.advanced(by: .seconds(RemoteTimeout.deviceRequest)))
  }
  func delete(handles: [UInt32], until deadline: ContinuousClock.Instant) async throws {
    guard session.available, session.isOpen else { throw RemoteError.posix(EIO) }
    guard canDelete else { throw RemoteError.posix(EACCES) }
    guard handles.allSatisfy({ self.handles.contains($0) }) else { throw RemoteError.posix(ENOENT) }
    do { try await session.delete(handles: handles, until: deadline) } catch {
      throw CameraUSBErrorMapper.map(error)
    }
    self.handles.subtract(handles)
  }
}
