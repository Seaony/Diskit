import Core
import SwiftUI

struct HelpView: View {
  private let topics: [HelpTopic] = [
    HelpTopic(
      symbol: "smartphone",
      color: .green,
      title: L("安卓手机"),
      steps: [
        L("在手机设置中打开开发者选项和 USB 调试，然后用数据线连接 Mac。"),
        L("首次测试连接时，在手机上允许这台 Mac 调试。"),
        L("无线调试需要 Android 11 或更新版本。打开无线调试后，选择“使用配对码配对设备”。"),
        L("在同一局域网中连接一次后，Kayoi 会在设备重新出现时找到它。"),
      ]),
    HelpTopic(
      symbol: "desktopcomputer",
      color: .blue,
      title: L("SMB 共享（Windows / Mac / NAS）"),
      steps: [
        L("在 Windows 或 Mac 上开启文件共享，并确认共享目录已有读写权限。"),
        L("填写电脑的 IP 地址或主机名、用户名、密码和共享名。"),
        L("微软账户请填写邮箱和账户密码，不要填写 PIN。"),
      ]),
    HelpTopic(
      symbol: "network",
      color: .teal,
      title: L("WebDAV 与 NFS"),
      steps: [
        L("WebDAV 支持 HTTP、HTTPS，以及坚果云、Nextcloud、ownCloud、群晖和威联通等常见服务。"),
        L("使用 WebDAV 时填写完整服务器地址和路径，并优先使用服务商提供的应用密码。"),
        L("NFS 需要填写 NAS 地址和导出路径，同时在 NAS 上允许这台 Mac 访问。"),
      ]),
    HelpTopic(
      symbol: "camera",
      color: .primary,
      title: L("相机"),
      steps: [
        L("用数据线连接相机，先在“图像捕捉”中确认 Mac 能识别它。"),
        L("退出图像捕捉后再打开 Kayoi，避免两个 App 同时占用相机。"),
        L("相机文件以只读方式浏览和导出；相机支持时可以直接删除。"),
      ]),
    HelpTopic(
      symbol: "externaldrive.badge.icloud",
      color: .orange,
      title: L("对象存储"),
      steps: [
        L("支持 Amazon S3、Cloudflare R2、阿里云 OSS、腾讯云 COS、七牛 Kodo、MinIO 和 Backblaze B2。"),
        L("先创建目标存储桶，再生成只允许访问该桶的访问密钥。"),
        L("填写服务地址、区域、存储桶、Access Key 和 Secret Key；MinIO 使用自己的服务器地址。"),
      ]),
    HelpTopic(
      symbol: "cloud",
      color: .purple,
      title: L("官方授权网盘"),
      steps: [
        L("阿里云盘、百度网盘、115、123 云盘、OneDrive、Google Drive 和 Dropbox 使用官方授权。"),
        L("Kayoi 会打开服务商授权页，完成后自动返回。应用凭据只在构建配置中提供。"),
        L("百度网盘只能访问应用专属目录；非会员可能受到速度和文件大小限制。"),
        L("登录过期时，在位置右侧选择“重新登录”。"),
      ]),
    HelpTopic(
      symbol: "cloud.fill",
      color: .blue,
      title: L("实验性网盘"),
      steps: [
        L("夸克和 UC 网盘使用网页登录；PikPak 使用账号密码登录。"),
        L("天翼、移动和迅雷网盘需要从已登录网页复制登录信息；蓝奏云支持账号登录信息或公开分享链接。"),
        L("这些服务使用非官方接口，可能随服务商更新暂时失效。"),
        L("蓝奏云为只读；迅雷支持浏览、上传和整理文件。"),
        L("登录过期时，在位置行右侧选择“重新登录”。"),
      ]),
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Kayoi 帮助").font(.system(size: 25, weight: .semibold))
          Text("连接设备、电脑、相机和网盘前，可以在这里查看准备步骤。")
            .font(.subheadline).foregroundStyle(.secondary)
        }

        ForEach(topics) { topic in
          VStack(alignment: .leading, spacing: 12) {
            Label(topic.title, systemImage: topic.symbol)
              .font(.headline).foregroundStyle(topic.color)
            ForEach(Array(topic.steps.enumerated()), id: \.offset) { index, step in
              HStack(alignment: .top, spacing: 10) {
                Text("\(index + 1)")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(KayoiTheme.accent)
                  .frame(width: 22, height: 22)
                  .background(KayoiTheme.selection, in: Circle())
                Text(step).font(.callout).fixedSize(horizontal: false, vertical: true)
              }
            }
          }
          .padding(18)
          .background(KayoiTheme.surface, in: RoundedRectangle(cornerRadius: 12))
          .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(KayoiTheme.border)
          }
        }

        Text("文件仍由各设备或服务保存。Kayoi 只保留连接配置和必要的本地缓存。")
          .font(.caption).foregroundStyle(.secondary)
      }.padding(24)
    }
    .frame(width: 560, height: 620)
    .background(KayoiTheme.background)
  }
}

private struct HelpTopic: Identifiable {
  var id: String { title }
  let symbol: String
  let color: Color
  let title: String
  let steps: [String]
}
