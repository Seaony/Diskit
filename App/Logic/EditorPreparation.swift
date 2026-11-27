import Core
import Foundation

// 连接指南文案里的标记（Markdown 行内语法）：
// **界面上要找、要点的名字** 用主文字色加中粗，*关键要求* 加虚线下划线，~~限制和注意~~ 用警告色（橙色）
enum EditorPreparation {
  // 去掉标记的纯文字，给连接失败建议等只显示文字的地方用
  static func plainSteps(for kind: ConnectionKind) -> [String] {
    steps(for: kind).map { step in
      let parsed = try? AttributedString(
        markdown: step, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
      return parsed.map { String($0.characters) } ?? step
    }
  }

  static func steps(for kind: ConnectionKind) -> [String] {
    switch kind {
    case .androidUSB, .androidWiFi, .androidMTP:
      [
        L("用*能传输数据的数据线*连接，解锁设备，在设备弹出的 USB 选项里选**文件传输**，插上就能读写。"),
        L("~~Android File Transfer 开着时会占住设备~~，请先退出它。"),
        L("想要更快的速度，可在设置中开启**开发者选项**，再打开 **USB 调试**，并在设备上**允许**这台 Mac。小米、OPPO、vivo、三星的入口可能不同，可在设置中搜索**开发者选项**。"),
        L("无线连接需打开**无线调试**，并输入设备当前显示的*配对码*；~~鸿蒙 NEXT 不支持 ADB~~，不能用无线调试和 USB 调试。"),
      ]
    case .smb:
      [
        L("在 Windows 的网络设置中开启**文件和打印机共享**，并给账户授予*目标文件夹的访问权限*。"),
        L("Microsoft 账户请填写*邮箱和账户密码*，~~不是登录电脑时使用的 PIN~~。"),
        L("Mac 或 NAS 请先开启 **SMB 文件共享**。"),
      ]
    case .cameraUSB:
      [L("用*支持数据传输的 USB 线*连接相机，并在相机上**允许访问存储卡**。"), L("退出**图像捕捉**或其他正在占用相机的应用。")]
    case .webdav, .webdavHTTPS:
      [L("复制服务提供商给出的*完整 WebDAV 地址*；它通常包含文件夹路径。"), L("如果服务提供应用密码，请使用**应用密码**而不是网页登录密码。")]
    case .nfs: [L("确认服务器的*导出路径*，并允许这台 Mac 访问。")]
    case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2:
      [L("准备*存储桶、区域和完整服务地址*。"), L("创建只允许访问目标存储桶的密钥，~~不要使用主账号密钥~~。")]
    case .lanzou: [L("可登录账号，或填写*公开分享链接*；有分享密码时一并填写。"), L("~~蓝奏云在当前版本中只读~~。")]
    default: [L("准备服务商账号，在*服务商自己的登录页面*完成授权。")]
    }
  }

  static func colorName(_ value: String) -> String {
    switch value {
    case "blue": L("蓝色")
    case "green": L("绿色")
    case "orange": L("橙色")
    case "red": L("红色")
    case "purple": L("紫色")
    case "pink": L("粉色")
    case "teal": L("青色")
    default: L("灰色")
    }
  }
}
