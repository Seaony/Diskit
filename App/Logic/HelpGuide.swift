import Core
import Foundation

struct HelpGuide: Identifiable {
  let kind: ConnectionKind
  var id: String { kind.rawValue }

  static let all = ConnectionKind.allCases.filter { $0 != .webdavHTTPS }.map(HelpGuide.init)

  var group: HelpGroup {
    switch kind {
    case .androidUSB, .androidWiFi, .ricohGR, .cameraUSB: .devices
    case .smb, .webdav, .webdavHTTPS, .nfs: .network
    case .aliyunDrive, .baiduDrive, .drive115, .drive123, .oneDrive, .googleDrive, .dropbox: .cloud
    case .quark, .ucDrive, .tianyiDrive, .mobileCloud, .thunderDrive, .pikPak, .lanzou:
      .experimental
    case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2:
      .objectStorage
    }
  }

  var introduction: String {
    switch group {
    case .devices:
      kind == .androidUSB || kind == .androidWiFi
        ? L("连接前先在手机上开启调试，并允许这台 Mac 访问。")
        : L("用数据线连接相机，读取照片前先确认相机允许电脑访问。")
    case .network: L("把已有的网络共享挂载到 Finder，文件仍保存在原来的电脑或服务器上。")
    case .cloud: L("在服务商自己的授权页完成登录，Kayoi 只保存连接所需的登录信息。")
    case .experimental: L("这些位置使用非官方接口，可能随服务商更新暂时失效。")
    case .objectStorage: L("连接已有的存储桶，并使用只允许访问该存储桶的访问密钥。")
    }
  }

  var steps: [HelpParagraph] {
    switch kind {
    case .androidUSB:
      [
        .init("developer", L("在手机设置中开启开发者选项和 USB 调试，再用支持数据传输的数据线连接 Mac。")),
        .init("authorize", L("首次测试连接时，解锁手机，在授权提示中允许这台 Mac。")),
        .init("brands", L("小米、OPPO、vivo 和三星手机的开关位置可能不同。请在设置中搜索“USB 调试”，并确认厂商的安全设置允许 USB 调试。")),
        .init("unsupported", L("鸿蒙 NEXT 不支持 ADB，不能通过这两种安卓连接方式访问。")),
      ]
    case .androidWiFi:
      [
        .init("version", L("无线调试需要 Android 11 或更新版本。让 Mac 和手机连接同一个局域网。")),
        .init("pairing", L("在开发者选项中打开无线调试，再选择“使用配对码配对设备”。")),
        .init("code", L("在 Kayoi 中选择发现的手机，输入手机显示的 6 位配对码。配对码过期后，请重新打开手机上的配对窗口。")),
        .init("unsupported", L("鸿蒙 NEXT 不支持 ADB，不能通过这两种安卓连接方式访问。")),
      ]
    case .smb:
      [
        .init("sharing", L("在 Windows、Mac 或 NAS 上开启文件共享，并为要连接的文件夹设置访问权限。")),
        .init("address", L("填写电脑的 IP 地址或主机名，再填写用户名、密码和共享名。共享名不等于电脑上的完整文件路径。")),
        .init("microsoft", L("微软账户请填写邮箱和账户密码，不要填写 PIN。匿名共享才选择访客。")),
      ]
    case .webdav, .webdavHTTPS:
      [
        .init(
          "enable",
          L("先在服务商或 NAS 中开启 WebDAV。可使用坚果云、Nextcloud、ownCloud、群晖、威联通及 OpenList / AList 等服务。")),
        .init("address", L("复制服务商提供的完整 WebDAV 地址，保留路径，并优先使用 HTTPS。")),
        .init("password", L("需要应用密码的服务，请先在其安全设置中创建应用密码，不要填网页登录密码。")),
      ]
    case .nfs:
      [
        .init("enable", L("在 NAS 或服务器上开启 NFS，并创建导出目录。")),
        .init("permission", L("在服务端允许这台 Mac 的 IP 地址访问，再填写服务器地址和完整导出路径。")),
        .init("network", L("请在可信的局域网中使用 NFS，访问权限由服务器上的导出设置决定。")),
      ]
    case .ricohGR, .cameraUSB:
      [
        .init("connection", L("用支持数据传输的数据线连接相机，并选择相机提供的电脑传输模式。")),
        .init("recognition", L("先在“图像捕捉”中确认 Mac 能识别相机，然后退出图像捕捉，避免同时占用设备。")),
        .init("permission", L("如果相机询问是否允许访问，请先在相机上确认，再回到 Kayoi 测试连接。")),
      ]
    case .aliyunDrive, .baiduDrive, .drive115, .drive123, .oneDrive, .googleDrive, .dropbox:
      [
        .init("login", L("添加位置后点击登录，在服务商自己的页面选择账号并完成授权。")),
        .init("return", L("授权完成后返回 Kayoi，确认账号信息，再测试并保存位置。")),
      ]
        + (kind == .baiduDrive
          ? [
            .init("app-folder", L("百度网盘只访问为 Kayoi 授权的应用目录，不能浏览账号中的其他文件。"))
          ] : [])
    case .pikPak:
      [
        .init("login", L("添加 PikPak 位置，填写账号和密码后登录。")),
        .init("verification", L("如果服务商要求验证，请先在服务商页面完成验证，再回到 Kayoi 重试。")),
        .init("save", L("确认登录的账号无误后，测试并保存位置。")),
      ]
    case .lanzou:
      [
        .init("mode", L("选择账号登录或分享链接。分享链接需要密码时，请填写分享者提供的密码。")),
        .init("login", L("账号方式请在蓝奏云登录页完成登录，等待 Kayoi 识别账号，再测试并保存位置。")),
        .init("alternative", L("如果未能识别账号，请展开“其他登录方式”，按说明复制并粘贴登录信息，再验证并保存。不要把登录信息发给其他人。")),
        .init("readonly", L("蓝奏云位置只能读取和下载，不能上传、改名、移动或删除文件。")),
      ]
    case .quark, .ucDrive, .tianyiDrive, .mobileCloud, .thunderDrive:
      [
        .init("login", L("点击登录，在服务商自己的页面扫码或输入账号信息。")),
        .init("return", L("登录完成后返回 Kayoi，确认账号信息，再测试并保存位置。")),
        .init("alternative", L("网页登录无法完成时，可在“其他登录方式”中查看替代步骤。不要把登录信息发给其他人。")),
      ]
        + (kind == .tianyiDrive
          ? [
            .init("family", L("选择家庭空间时，请确认当前账号是该家庭的成员，再选择要连接的家庭空间。"))
          ] : [])
    case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2:
      [
        .init("bucket", L("先在服务商控制台创建存储桶，并准备允许访问该桶的访问密钥。")),
        .init("connection", L("填写服务地址、区域、存储桶名称、访问密钥 ID 和访问密钥。MinIO 使用自己的服务器地址。")),
        .init("permissions", L("只授予需要的读写权限。要上传或整理文件，还需要相应的写入、列出和删除权限。")),
      ]
    }
  }

  var questions: [HelpQuestion] {
    switch group {
    case .devices:
      return [
        .init("missing", L("找不到设备怎么办？"), L("解锁设备并检查数据线；部分数据线只能充电。退出可能占用设备的手机调试工具或图像捕捉，再重新连接。")),
        .init(
          "wifi", L("无线连接为什么断开了？"), L("手机和 Mac 需要在同一局域网。访客网络、VPN 或路由器的设备隔离可能阻止连接；无线调试关闭后也需要重新开启。")),
      ].filter { kind == .androidWiFi || $0.id != "wifi" }
    case .network:
      return [
        .init("login", L("为什么提示没有访问权限？"), L("检查用户名、密码和共享目录权限。账号能登录网页，不代表它也有文件共享的访问权限。")),
        .init(
          "quit", L("退出 Kayoi 会推出共享吗？"),
          L("不会。SMB、WebDAV 和 NFS 由系统保持挂载；需要断开时，请在 Kayoi 或 Finder 中推出。")),
      ]
    case .cloud, .experimental:
      var result = [
        HelpQuestion("expired", L("登录过期后怎么办？"), L("在位置右侧选择“重新登录”，重新完成服务商要求的授权或验证。")),
        HelpQuestion(
          "limits", L("连接成功后为什么仍不能访问部分文件？"), L("服务商可能限制账号权限、分享访问、会员权益或请求频率。请先确认该账号在服务商页面能访问目标文件。")),
      ]
      if kind == .aliyunDrive {
        result.append(
          .init(
            "membership", L("阿里云盘为什么提示权益限制？"), L("部分第三方访问能力需要服务商提供的权益。请在阿里云盘中确认账号的第三方应用权益是否有效。")))
      }
      return result
    case .objectStorage:
      return [
        .init(
          "endpoint", L("为什么服务地址正确却连不上？"), L("请核对存储桶所在区域、地址格式和密钥权限。服务地址应来自服务商控制台，而不是存储桶的网页管理链接。")),
      ]
    }
  }

  var capabilities: [HelpCapability] {
    let camera = kind == .ricohGR || kind == .cameraUSB
    let readOnly = camera || kind == .lanzou
    return [
      .init("read", L("浏览与读取"), .supported),
      .init("write", L("上传与新建文件夹"), readOnly ? .unavailable : .supported),
      .init("move", L("改名与移动"), readOnly ? .unavailable : .supported),
      .init(
        "delete", L("删除"), kind == .lanzou ? .unavailable : camera ? .deviceDependent : .supported),
    ]
  }

  func matches(_ query: String, title: String) -> Bool {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return true }
    let searchable =
      [title, kind.rawValue, group.title, introduction, aliases]
      + steps.map(\.text) + questions.flatMap { [$0.title, $0.answer] }
    return searchable.contains { $0.localizedStandardContains(query) }
  }

  private var aliases: String {
    switch kind {
    case .androidUSB, .androidWiFi: "Android USB ADB Wi-Fi 安卓 手机 小米 OPPO vivo Samsung 三星"
    case .smb: "SMB Windows Mac NAS 共享"
    case .webdav, .webdavHTTPS:
      "WebDAV HTTPS Nextcloud ownCloud QNAP Synology OpenList AList 坚果云 群晖 威联通"
    case .nfs: "NFS NAS 网络共享"
    case .ricohGR: "Ricoh GR IV 理光 相机 camera"
    case .cameraUSB: "USB 相机 camera"
    case .aliyunDrive: "Aliyun Alipan 阿里云盘"
    case .baiduDrive: "Baidu 百度网盘"
    case .drive115: "115 网盘"
    case .drive123: "123 云盘"
    case .oneDrive: "OneDrive Microsoft 微软"
    case .googleDrive: "Google Drive 谷歌"
    case .dropbox: "Dropbox"
    case .quark: "Quark 夸克"
    case .ucDrive: "UC 网盘"
    case .tianyiDrive: "天翼 云盘 189"
    case .mobileCloud: "移动 云盘 139"
    case .thunderDrive: "迅雷 Xunlei Thunder"
    case .pikPak: "PikPak"
    case .lanzou: "蓝奏 Lanzou 分享"
    case .s3: "Amazon AWS S3"
    case .cloudflareR2: "Cloudflare R2"
    case .aliyunOSS: "阿里云 OSS Aliyun"
    case .tencentCOS: "腾讯云 COS Tencent"
    case .qiniuKodo: "七牛 Kodo Qiniu"
    case .minIO: "MinIO"
    case .backblazeB2: "Backblaze B2"
    }
  }
}
