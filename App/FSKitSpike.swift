import FSKit
import Foundation
import Security

/// M7 验证入口：只在带 `--fskit-spike` 参数启动时运行，做完就退出，不进正常界面。
/// 用法：Kayoi --fskit-spike seed | status | mount <URL> | unmount <路径> | settings
enum FSKitSpike {
  /// 任何一步失败就记下来，退出码给 1，方便脚本判断验证结果
  nonisolated(unsafe) private static var failed = false

  private static func fail(_ message: String) {
    failed = true
    print(message)
  }

  static func runIfRequested() {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--fskit-spike") else { return }
    let rest = Array(arguments.dropFirst(index + 1))
    switch rest.first {
    case "seed": seed()
    case "status": status()
    case "mount" where rest.count > 1:
      if #available(macOS 27, *) { mount(rest[1]) } else { fail("FSClient 挂载接口需要 macOS 27") }
    case "unmount" where rest.count > 1: unmount(rest[1])
    case "settings":
      if #available(macOS 27, *) {
        if FSClient.shared.openFileSystemExtensionsSettings() { print("已打开系统设置") } else { fail("打开系统设置失败") }
      } else { fail("需要 macOS 27") }
    default: fail("用法：--fskit-spike seed | status | mount <URL> | unmount <路径> | settings")
    }
    exit(failed ? 1 : 0)
  }

  /// 往 App Group 写验证文件、往共享钥匙串写验证条目，扩展挂载时读出来放进 readme.txt。
  private static func seed() {
    let stamp = "主 App 写入于 \(Date().formatted(.iso8601))"
    if let url = SpikeShared.groupFile {
      do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(stamp.utf8).write(to: url, options: .atomic)
        print("App Group 文件已写入：\(url.path)")
      } catch { fail("App Group 文件写入失败：\(error)") }
    } else {
      fail("拿不到 App Group 容器")
    }
    SecItemDelete(SpikeShared.keychainQuery() as CFDictionary)
    var add = SpikeShared.keychainQuery()
    add[kSecValueData as String] = Data(stamp.utf8)
    let status = SecItemAdd(add as CFDictionary, nil)
    if status == errSecSuccess { print("共享钥匙串条目已写入") } else { fail("共享钥匙串写入失败 OSStatus \(status)") }
    print("回读：钥匙串=\(SpikeShared.readKeychain())；文件=\(SpikeShared.readGroupFile())")
  }

  private static func status() {
    wait { done in
      FSClient.shared.fetchInstalledExtensions { identities, error in
        if let error { fail("读取扩展列表失败：\(error)") }
        for identity in identities ?? [] {
          print("\(identity.bundleIdentifier) 已启用=\(identity.isEnabled) \(identity.url.path)")
        }
        if identities?.isEmpty ?? true { print("系统里没有 FSKit 扩展") }
        done()
      }
    }
  }

  @available(macOS 27, *)
  private static func mount(_ text: String) {
    guard let url = URL(string: text) else { return fail("URL 不合法：\(text)") }
    let started = Date()
    wait { done in
      FSClient.shared.mountSingleVolume(
        resource: FSGenericURLResource(url: url), bundleID: "com.seaony.Kayoi.FS", options: []
      ) { path, error in
        let seconds = Date().timeIntervalSince(started).formatted(.number.precision(.fractionLength(2)))
        if let path { print("已挂载：\(path.path)（\(seconds) 秒）") } else { fail("挂载失败（\(seconds) 秒）：\(String(describing: error))") }
        done()
      }
    }
  }

  private static func unmount(_ path: String) {
    wait { done in
      FileManager.default.unmountVolume(at: URL(filePath: path), options: []) { error in
        if let error { fail("推出失败：\(error)") } else { print("已推出：\(path)") }
        done()
      }
    }
  }

  /// 命令行模式下没有主循环，等回调结束再退出。
  private static func wait(_ body: (@escaping @Sendable () -> Void) -> Void) {
    let semaphore = DispatchSemaphore(value: 0)
    body { semaphore.signal() }
    if semaphore.wait(timeout: .now() + 60) == .timedOut { fail("等待超时 60 秒") }
  }
}
