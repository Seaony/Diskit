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
