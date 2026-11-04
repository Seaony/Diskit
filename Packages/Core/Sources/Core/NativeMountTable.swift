import Darwin
import Foundation

// 只读取系统挂载表；身份匹配和容量缓存留在服务层。
enum NativeMountTable {
  static func entries() -> [SystemSMBService.MountEntry] {
    var table: UnsafeMutablePointer<statfs>?
    let count = getmntinfo(&table, MNT_NOWAIT)
    guard let table else { return [] }
    return (0..<Int(count)).map { entry(table[$0]) }
  }

  static func capacity(_ url: URL) -> SystemSMBService.MountEntry? {
    var value = statfs()
    guard statfs(url.path, &value) == 0 else { return nil }
    return entry(value)
  }

  private static func entry(_ input: statfs) -> SystemSMBService.MountEntry {
    var value = input
    let type = withUnsafePointer(to: &value.f_fstypename) {
      String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
    }
    let source = withUnsafePointer(to: &value.f_mntfromname) {
      String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
    }
    let path = withUnsafePointer(to: &value.f_mntonname) {
      String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
    }
    return SystemSMBService.MountEntry(
      type: type, source: source, path: URL(fileURLWithPath: path),
      filesystemID: withUnsafeBytes(of: value.f_fsid) { Data($0) },
      availableBytes: MountCapacityRequest.bytes(blocks: value.f_bavail, blockSize: value.f_bsize))
  }
}
