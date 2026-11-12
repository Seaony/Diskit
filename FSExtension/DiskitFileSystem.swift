import Core
import FSKit
import Foundation
import OSLog
import Synchronization

final class DiskitFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, @unchecked Sendable {
  private let backends = Mutex<[UUID: RemoteVolumeBackend]>([:])
  private let logger = Logger(subsystem: "com.seaony.Diskit.FS", category: "FileSystemLifecycle")

  func probeResource(
    resource: FSResource, replyHandler: @escaping (FSProbeResult?, Error?) -> Void
  ) {
    do {
      let connection = try savedConnection(resource)
      logger.info(
        "probe connection=\(connection.id.uuidString, privacy: .public) kind=\(connection.kind.rawValue, privacy: .public)"
      )
      replyHandler(
        .usable(name: connection.name, containerID: FSContainerIdentifier(uuid: connection.id)), nil
      )
    } catch {
      let value = error as NSError
      logger.notice("probe rejected domain=\(value.domain, privacy: .public) code=\(value.code)")
      replyHandler(.notRecognized, nil)
    }
  }

  func loadResource(
    resource: FSResource, options: FSTaskOptions,
    replyHandler: @escaping (FSVolume?, Error?) -> Void
  ) {
    let reply = FileSystemReply(replyHandler)
    let connection: Connection
    let location: SharedStorageLocation
    do {
      connection = try savedConnection(resource)
      location = try SharedStorageLocation()
    } catch {
      replyHandler(nil, Self.filesystemError(error))
      return
    }
    Task {
      var backend: RemoteVolumeBackend?
      do {
        logger.info(
          "load connection=\(connection.id.uuidString, privacy: .public) kind=\(connection.kind.rawValue, privacy: .public)"
        )
        let provider = try await RemoteProviderFactory.make(
          for: connection, secrets: SharedKeychainStore(), info: Bundle.main.infoDictionary ?? [:])
        let created = RemoteVolumeBackend(
          provider: provider, connectionID: connection.id, kind: connection.kind,
          cacheRoot: location.cacheDirectory,
          replacesExisting: connection.kind == .androidUSB || connection.kind == .androidWiFi
            || connection.kind == .aliyunDrive)
        backend = created
        let space = try await created.connect()
        // 有些 Provider 的 connect 只检查参数，读根目录后才确认可以实际访问。
        _ = try await created.list(RemotePath("/"))
        let volume = DiskitRemoteVolume(connection: connection, backend: created, space: space)
        backends.withLock { $0[connection.id] = created }
        containerStatus = .ready
        logger.info("load ready connection=\(connection.id.uuidString, privacy: .public)")
        reply.body(volume, nil)
      } catch {
        FileSystemLoginEvent.postIfNeeded(error, connection: connection)
        if let backend { await backend.disconnect() }
        let value = error as NSError
        logger.error(
          "load failed connection=\(connection.id.uuidString, privacy: .public) domain=\(value.domain, privacy: .public) code=\(value.code)"
        )
        reply.body(nil, Self.filesystemError(error))
      }
    }
  }

  func unloadResource(
    resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (Error?) -> Void
  ) {
    guard let host = (resource as? FSGenericURLResource)?.url.host,
      let id = UUID(uuidString: host)
    else {
      replyHandler(POSIXError(.EINVAL))
      return
    }
    let backend = backends.withLock { $0.removeValue(forKey: id) }
    let reply = FileSystemReply(replyHandler)
    Task {
      if let backend { await backend.disconnect() }
      logger.info("unload connection=\(id.uuidString, privacy: .public)")
      reply.body(nil)
    }
  }

  private func savedConnection(_ resource: FSResource) throws -> Connection {
    guard let url = (resource as? FSGenericURLResource)?.url else { throw POSIXError(.EINVAL) }
    let location = try SharedStorageLocation()
    guard SharedStorageMigration.isComplete(in: location) else { throw POSIXError(.EAGAIN) }
    return try FileSystemAddress.connection(
      for: url, in: ConnectionRepository(location: location).load())
  }

  private static func filesystemError(_ error: Error) -> Error {
    if let failure = error as? any LoginRequiredFailure, failure.requiresLogin {
      return POSIXError(.EACCES)
    }
    let value = error as NSError
    if value.domain == NSPOSIXErrorDomain {
      switch Int32(clamping: value.code) {
      case ENODEV, ENETDOWN, ENETUNREACH, ECONNRESET, ENOTCONN, EPIPE:
        return POSIXError(.EIO)
      default: return error
      }
    }
    return POSIXError(.EIO)
  }
}

private final class FileSystemReply<Body>: @unchecked Sendable {
  let body: Body
  init(_ body: Body) { self.body = body }
}
