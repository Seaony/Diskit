import CryptoKit
import FSKit
import Foundation
import os

let spikeLog = Logger(subsystem: "com.seaony.Kayoi.FS", category: "spike")

/// 验证阶段的文件系统：认 PLAN 里的四种 URL，挂出一个内存假数据卷。
final class KayoiFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, @unchecked Sendable {
  private static let schemes: Set<String> = ["kayoi-adb", "kayoi-gr", "kayoi-aliyun", "kayoi-quark"]

  func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
    guard let url = (resource as? FSGenericURLResource)?.url, let scheme = url.scheme?.lowercased(),
      Self.schemes.contains(scheme)
    else {
      replyHandler(.notRecognized, nil)
      return
    }
    spikeLog.info("probe \(url.absoluteString, privacy: .public)")
    replyHandler(.usable(name: url.host() ?? "Kayoi", containerID: FSContainerIdentifier(uuid: Self.uuid(for: url))), nil)
  }

  func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
    guard let url = (resource as? FSGenericURLResource)?.url else {
      replyHandler(nil, POSIXError(.EINVAL))
      return
    }
    spikeLog.info("load \(url.absoluteString, privacy: .public) options=\(options.taskOptions, privacy: .public)")
    let name = url.host() ?? "Kayoi"
    let readme = """
      Kayoi FSKit 验证卷
      URL：\(url.absoluteString)
      App Group 文件：\(SpikeShared.readGroupFile())
      共享钥匙串：\(SpikeShared.readKeychain())

      """
    spikeLog.info("shared check: \(readme, privacy: .public)")
    let volume = SpikeVolume(
      volumeID: FSVolume.Identifier(uuid: Self.uuid(for: url)), volumeName: FSFileName(string: name), readme: readme)
    // 主机名是 usbcheck 时，在扩展进程里连 USB 安卓手机，结果写进卷根目录的 usb-check.txt
    if url.host() == "usbcheck" {
      volume.setRootFile("usb-check.txt", text: "检查中…\n")
      Task {
        let result = await SpikeUSBCheck.run()
        spikeLog.info("usb check: \(result, privacy: .public)")
        volume.setRootFile("usb-check.txt", text: result + "\n")
      }
    }
    containerStatus = .ready
    replyHandler(volume, nil)
  }

  func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping ((any Error)?) -> Void) {
    spikeLog.info("unload")
    replyHandler(nil)
  }

  /// 同一个 URL 每次得到同一个卷 ID，系统据此认出是同一个卷。
  private static func uuid(for url: URL) -> UUID {
    let digest = Array(Insecure.MD5.hash(data: Data(url.absoluteString.utf8)))
    return NSUUID(uuidBytes: digest) as UUID
  }
}
