import Core
import Foundation

extension ConnectionKind {
  var title: String {
    switch self {
    case .androidUSB: L("Android 手机")
    case .androidWiFi: L("Android 手机（无线）")
    case .smb: L("SMB 共享")
    case .cameraUSB: L("相机（USB）")
    case .webdav: L("WebDAV")
    case .webdavHTTPS: L("WebDAV")
    case .nfs: L("NFS")
    case .s3: L("Amazon S3")
    case .cloudflareR2: L("Cloudflare R2")
    case .aliyunOSS: L("阿里云 OSS")
    case .tencentCOS: L("腾讯云 COS")
    case .qiniuKodo: L("七牛 Kodo")
    case .minIO: L("MinIO")
    case .backblazeB2: L("Backblaze B2")
    case .quark: L("夸克网盘")
    case .ucDrive: L("UC 网盘")
    case .tianyiDrive: L("天翼云盘")
    case .mobileCloud: L("移动云盘")
    case .thunderDrive: L("迅雷云盘")
    case .pikPak: L("PikPak")
    case .lanzou: L("蓝奏云")
    }
  }
  var defaultName: String {
    switch self {
    case .androidUSB, .androidWiFi: L("我的 Android 手机")
    case .smb: L("我的 SMB 共享")
    case .cameraUSB: L("我的相机")
    default: title
    }
  }
  var isExperimental: Bool {
    switch self {
    case .quark, .ucDrive, .tianyiDrive, .mobileCloud, .thunderDrive, .pikPak, .lanzou: true
    default: false
    }
  }
}
