import Darwin
import DiskArbitration
import Foundation
import OSLog

struct NativeVolumeUnmounter: Sendable {
  typealias Completion = @Sendable (Result<Void, Error>) -> Void

  struct Mount: Equatable, Sendable {
    let type: String
    let source: String
    let path: String
    let filesystemID: Data
  }

  struct Operations: Sendable {
    var mount: @Sendable (String) -> Mount?
    var fileManager: @Sendable (URL, @escaping Completion) -> Void
    var diskArbitration: @Sendable (Mount, @escaping Completion) -> Void
    var recordFailure: @Sendable (Error) -> Void

    static let live = Operations(
      mount: NativeVolumeUnmounter.mountSnapshot,
      fileManager: { url, completion in
        FileManager.default.unmountVolume(at: url, options: []) { error in
          completion(error.map { .failure($0) } ?? .success(()))
        }
      },
      diskArbitration: NativeVolumeUnmounter.unmountWithDiskArbitration,
      recordFailure: { error in
        NativeVolumeUnmounter.logger.error("原生推出失败：\(ErrorDiagnostics.summary(error), privacy: .public)")
      })
  }

  private static let logger = Logger(subsystem: "com.seaony.Diskit", category: "mount")
  let operations: Operations

  init(operations: Operations = .live) { self.operations = operations }

  func unmount(_ url: URL, completion: @escaping Completion) {
    let path = url.path
    let original = operations.mount(path)
    let target = URL(filePath: path, directoryHint: .isDirectory)
    operations.fileManager(target) { result in
      guard case .failure(let error) = result else { completion(result); return }
      operations.recordFailure(error)
      let value = error as NSError
      guard value.domain == NSCocoaErrorDomain, value.code == NSFileReadUnknownError,
        let original, original.type == "diskit", operations.mount(path) == original
      else {
        completion(.failure(error))
        return
      }
      operations.diskArbitration(original) { fallback in
        if case .failure(let secondary) = fallback {
          let value = secondary as NSError
          let combined = NSError(
            domain: value.domain, code: value.code,
            userInfo: [NSMultipleUnderlyingErrorsKey: [error, secondary]])
          operations.recordFailure(combined)
          completion(.failure(combined))
        } else {
          completion(fallback)
        }
      }
    }
  }

  private static func mountSnapshot(_ path: String) -> Mount? {
    let count = getfsstat(nil, 0, MNT_NOWAIT)
    guard count > 0 else { return nil }
    let capacity = Int(count)
    let mounts = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
    defer { mounts.deallocate() }
    let copied = getfsstat(mounts, Int32(clamping: capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT)
    guard copied > 0 else { return nil }
    var match: Mount?
    for index in 0..<min(capacity, Int(copied)) {
      var value = mounts[index]
      let mountedPath = withUnsafePointer(to: &value.f_mntonname) {
        String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
      }
      guard mountedPath == path else { continue }
      guard match == nil else { return nil }
      let type = withUnsafePointer(to: &value.f_fstypename) {
        String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
      }
      let source = withUnsafePointer(to: &value.f_mntfromname) {
        String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
      }
      match = Mount(type: type, source: source, path: mountedPath,
                    filesystemID: withUnsafeBytes(of: value.f_fsid) { Data($0) })
    }
    return match
  }

  private static func unmountWithDiskArbitration(_ mount: Mount, completion: @escaping Completion) {
    guard let session = DASessionCreate(kCFAllocatorDefault) else {
      completion(.failure(NSError(domain: NSCocoaErrorDomain, code: NSFileManagerUnmountUnknownError)))
      return
    }
    let queue = DispatchQueue(label: "com.seaony.Diskit.unmount")
    DASessionSetDispatchQueue(session, queue)
    let url = URL(filePath: mount.path, directoryHint: .isDirectory)
    guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else {
      DASessionSetDispatchQueue(session, nil)
      completion(.failure(NSError(domain: NSCocoaErrorDomain, code: NSFileManagerUnmountUnknownError)))
      return
    }
    // 创建 DA 对象期间也可能换卷；发出请求前再核对一次。
    guard mountSnapshot(mount.path) == mount else {
      DASessionSetDispatchQueue(session, nil)
      completion(.failure(POSIXError(.ESTALE)))
      return
    }
    let request = DiskArbitrationUnmountRequest(session: session, disk: disk, queue: queue,
                                               completion: completion)
    let context = Unmanaged.passRetained(request).toOpaque()
    DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), nativeVolumeDidUnmount, context)
  }

  static func diskArbitrationError(_ status: DAReturn) -> NSError {
    let raw = NSError(domain: NSMachErrorDomain, code: Int(status))
    if status == DAReturn(truncatingIfNeeded: kDAReturnBusy) {
      return NSError(domain: NSCocoaErrorDomain, code: NSFileManagerUnmountBusyError,
                     userInfo: [NSUnderlyingErrorKey: raw])
    }
    return raw
  }
}

private final class DiskArbitrationUnmountRequest: @unchecked Sendable {
  let session: DASession
  let disk: DADisk
  let queue: DispatchQueue
  let completion: NativeVolumeUnmounter.Completion

  init(session: DASession, disk: DADisk, queue: DispatchQueue,
       completion: @escaping NativeVolumeUnmounter.Completion) {
    self.session = session
    self.disk = disk
    self.queue = queue
    self.completion = completion
  }

  func finish(_ dissenter: DADissenter?) {
    DASessionSetDispatchQueue(session, nil)
    if let dissenter {
      completion(.failure(NativeVolumeUnmounter.diskArbitrationError(DADissenterGetStatus(dissenter))))
    } else {
      completion(.success(()))
    }
  }
}

// C 回调不属于 MainActor，队列由 DA 会话决定；原生结束前一直持有请求。
private func nativeVolumeDidUnmount(_ disk: DADisk, _ dissenter: DADissenter?,
                                   _ context: UnsafeMutableRawPointer?) {
  guard let context else { return }
  let request = Unmanaged<DiskArbitrationUnmountRequest>.fromOpaque(context).takeRetainedValue()
  request.finish(dissenter)
}
