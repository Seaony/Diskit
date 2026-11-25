import Core

enum ConnectionFailureAdvice {
  static func text(for kind: ConnectionKind) -> String {
    switch kind {
    case .androidUSB:
      L("请使用支持数据传输的线缆，解锁手机并开启 USB 调试。首次连接时，请在手机上允许这台电脑。")
    case .androidWiFi:
      L("请让手机和 Mac 连接同一 Wi-Fi，在手机的无线调试设置中打开“使用配对码配对设备”，并保持该页面开启。")
    case .cameraUSB, .smb, .webdav, .webdavHTTPS, .nfs,
      .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2, .lanzou:
      EditorPreparation.plainSteps(for: kind).joined(separator: "\n")
    default:
      L("请检查网络和登录信息，然后重试。")
    }
  }
}
