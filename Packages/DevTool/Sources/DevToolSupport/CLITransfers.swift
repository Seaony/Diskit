import ADB
import AliyunDrive
import ChinaWebDrive
import CloudDrive
import Core
import Darwin
import Foundation
import PikPakDrive
import Quark
import S3Drive
import TianyiDrive

enum CLITransfers {
  // 经过挂载卷的读取逻辑、每次读 1 MiB（和 Finder 复制时一样），最后报告用时和速度
  static func finderRead(
    _ provider: any RemoteFileProvider, kind: ConnectionKind, path: RemotePath,
    range: Range<Int64>?, output: (Data) throws -> Void, report: (String) -> Void
  ) async throws {
    let cache = FileManager.default.temporaryDirectory.appending(path: "diskit-dev-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: cache) }
    let backend = RemoteVolumeBackend(
      provider: provider, connectionID: UUID(), kind: kind, cacheRoot: cache, replacesExisting: true)
    _ = try await backend.connect()
    let started = ContinuousClock.now
    try await backend.open(path, writable: false)
    let size = try await backend.attributes(path).size
    var offset = range?.lowerBound ?? 0
    let end = min(size, range?.upperBound ?? size)
    var firstByte: Duration?
    while offset < end {
      let data = try await backend.read(path, offset: offset, length: Int(min(1 << 20, end - offset)))
      guard !data.isEmpty else { break }
      if firstByte == nil { firstByte = ContinuousClock.now - started }
      try output(data)
      offset += Int64(data.count)
    }
    try await backend.close(path)
    await backend.disconnect()
    let elapsed = (ContinuousClock.now - started).components
    let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    let bytes = offset - (range?.lowerBound ?? 0)
    report(
      String(
        format: "%lld 字节，首块 %@，共 %.1f 秒，%.1f MB/s", bytes,
        firstByte.map { "\($0)" } ?? "-", seconds, Double(bytes) / 1_048_576 / max(seconds, 0.001)))
  }

  static func upload(
    _ provider: any RemoteFileProvider, local: URL, remote: RemotePath,
    report: @escaping @Sendable (Int64, Int64?) -> Void
  ) async throws {
    try Task.checkCancellation()
    let values = try local.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey,
    ])
    guard values.isSymbolicLink != true else { throw RemoteError.unsupported }
    if values.isDirectory == true {
      try await provider.makeDirectory(remote)
      for child in try FileManager.default.contentsOfDirectory(
        at: local, includingPropertiesForKeys: nil)
      {
        try await upload(
          provider, local: child, remote: remote.appending(child.lastPathComponent), report: report)
      }
    } else {
      guard values.isRegularFile == true else { throw RemoteError.unsupported }
      let progress: @Sendable (Int64, Int64) -> Void = { report($0, $1) }
      if let value = provider as? GoogleDriveProvider { await value.onProgress(progress) }
      if let value = provider as? ADBProvider { await value.onProgress(progress) }
      if let value = provider as? AliyunProvider { await value.onProgress(progress) }
      if let value = provider as? QuarkProvider { await value.onProgress(progress) }
      if let value = provider as? PikPakProvider { await value.onProgress(progress) }
      if let value = provider as? TianyiProvider { await value.onProgress(progress) }
      if let value = provider as? MobileCloudProvider { await value.onProgress(progress) }
      if let value = provider as? XunleiProvider { await value.onProgress(progress) }
      if let value = provider as? S3Provider { await value.onProgress(progress) }
      if let value = provider as? BaiduDriveProvider { await value.onProgress(progress) }
      if let value = provider as? Drive115Provider { await value.onProgress(progress) }
      if let value = provider as? Drive123Provider { await value.onProgress(progress) }
      if let value = provider as? OneDriveProvider { await value.onProgress(progress) }
      if let value = provider as? DropboxProvider { await value.onProgress(progress) }
      try await provider.write(remote, from: local)
      report(Int64(values.fileSize ?? 0), Int64(values.fileSize ?? 0))
    }
  }

  static func download(
    _ provider: any RemoteFileProvider, remote: RemotePath, local: URL,
    report: @escaping @Sendable (Int64, Int64?) -> Void
  ) async throws {
    var existing = stat()
    if lstat(local.path, &existing) == 0 { throw RemoteError.posix(EEXIST) }
    guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let item = try await provider.stat(remote)
    guard item.path == remote else { throw RemoteError.invalidPath }
    let staging = local.deletingLastPathComponent().appending(
      path: ".diskit-download-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: staging) }
    let content = staging.appending(path: "content")
    try await materialize(provider, item: item, local: content, report: report)
    try Task.checkCancellation()
    guard renamex_np(content.path, local.path, UInt32(RENAME_EXCL)) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private static func materialize(
    _ provider: any RemoteFileProvider, item: RemoteItem, local: URL,
    report: @escaping @Sendable (Int64, Int64?) -> Void
  ) async throws {
    try Task.checkCancellation()
    if item.isDirectory {
      try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
      let prefix = item.path.value == "/" ? "/" : item.path.value + "/"
      for child in try await provider.list(item.path) {
        guard !child.name.isEmpty, child.name != ".", child.name != "..", !child.name.contains("/"),
          !child.name.contains("\0"),
          child.path.value.hasPrefix(prefix),
          !child.path.value.dropFirst(prefix.count).contains("/"), child.path != item.path
        else { throw RemoteError.invalidPath }
        try await materialize(
          provider, item: child, local: local.appending(path: child.name), report: report)
      }
    } else {
      guard item.size >= 0 else { throw RemoteError.protocolError }
      let descriptor = open(local.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
      guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      defer { try? handle.close() }
      var count: Int64 = 0
      for try await chunk in try await provider.read(item.path, range: nil) {
        try Task.checkCancellation()
        guard Int64(chunk.count) <= item.size - count else { throw RemoteError.protocolError }
        try handle.write(contentsOf: chunk)
        count += Int64(chunk.count)
        report(count, item.size)
      }
      guard count == item.size else { throw RemoteError.protocolError }
      try handle.synchronize()
      try handle.close()
      report(count, item.size)
    }
  }
}
