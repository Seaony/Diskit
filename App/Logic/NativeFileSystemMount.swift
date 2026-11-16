import AppKit
import Core
import Darwin
import Foundation
import OSLog
import FSKit
import ServiceManagement

@MainActor enum NativeFileSystemMount {
  static func enabled(completion: @escaping FileSystemCompletion<Bool?>) {
    FSClient.shared.fetchInstalledExtensions { identities, error in
      if let error { completion(.failure(error)) }
      else { completion(.success(identities?.first { $0.bundleIdentifier == "com.seaony.Diskit.FS" }?.isEnabled)) }
    }
  }

  static func mountClient(_ url: URL, completion: @escaping FileSystemCompletion<URL>) throws {
    guard #available(macOS 27, *) else { throw RemoteError.unsupported }
    FSClient.shared.mountSingleVolume(resource: FSGenericURLResource(url: url), bundleID: "com.seaony.Diskit.FS", options: []) { path, error in
      if let error { completion(.failure(error)) }
      else if let path { completion(.success(path)) }
      else { completion(.failure(POSIXError(.EIO))) }
    }
  }

  static func mountCommand(_ url: URL, point: URL, completion: @escaping FileSystemCompletion<URL>) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/sbin/mount")
    process.arguments = ["-F", "-t", "diskit", url.absoluteString, point.path]
    process.standardOutput = FileHandle.nullDevice
    // 失败原因只在 mount 的输出里，记进日志方便排查
    let errors = Pipe()
    process.standardError = errors
    process.terminationHandler = { [process] _ in
      process.terminationHandler = nil
      if process.terminationStatus == 0 { completion(.success(point)) }
      else {
        let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        Logger(subsystem: "com.seaony.Diskit", category: "mount").error(
          "mount 命令失败 status=\(process.terminationStatus) \(output, privacy: .public)")
        completion(.failure(
          FileSystemMountError.isConflictingExtension(commandOutput: output)
            ? FileSystemMountError.conflictingExtension : FileSystemMountError.commandFailed(process.terminationStatus)))
      }
    }
    // 不杀掉挂载命令；等系统给出结果，取消后的迟到成功也会被推出。
    try process.run()
  }

  static func unmount(_ url: URL, completion: @escaping FileSystemCompletion<Void>) {
    NativeVolumeUnmounter().unmount(url, completion: completion)
  }

  static func openSettings() -> Bool {
    if #available(macOS 27, *) { return FSClient.shared.openFileSystemExtensionsSettings() }
    SMAppService.openSystemSettingsLoginItems()
    return true
  }
}

enum NativeFileSystemMountTable {
  static func entries() -> [FileSystemMountService.MountEntry] {
    var table: UnsafeMutablePointer<statfs>?
    let count = getmntinfo(&table, MNT_NOWAIT)
    guard let table else { return [] }
    return (0..<Int(count)).map { entry(table[$0]) }
  }

  static func capacity(_ url: URL) -> FileSystemMountService.MountEntry? {
    var value = statfs()
    guard statfs(url.path, &value) == 0 else { return nil }
    return entry(value)
  }

  private static func entry(_ input: statfs) -> FileSystemMountService.MountEntry {
    var value = input
    let type = withUnsafePointer(to: &value.f_fstypename) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
    let source = withUnsafePointer(to: &value.f_mntfromname) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
    let path = withUnsafePointer(to: &value.f_mntonname) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
    let available = availableBytes(totalBlocks: value.f_blocks, availableBlocks: value.f_bavail, blockSize: value.f_bsize)
    return FileSystemMountService.MountEntry(type: type, source: source, path: URL(filePath: path, directoryHint: .isDirectory), filesystemID: withUnsafeBytes(of: value.f_fsid) { Data($0) }, availableBytes: available)
  }

  static func availableBytes(totalBlocks: UInt64, availableBlocks: UInt64, blockSize: UInt32) -> Int64? {
    guard totalBlocks > 0, blockSize > 0, let blocks = Int64(exactly: availableBlocks) else { return nil }
    let bytes = blocks.multipliedReportingOverflow(by: Int64(blockSize))
    return bytes.overflow ? nil : bytes.partialValue
  }
}
