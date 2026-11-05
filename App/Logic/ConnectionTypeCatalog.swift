import Core
import Foundation
import S3Drive

struct ConnectionTypeGroup: Identifiable {
  let title: String
  let kinds: [ConnectionKind]
  var id: String { title }
}

enum ConnectionTypeCatalog {
  static var groups: [ConnectionTypeGroup] {
    [
      .init(title: L("设备"), kinds: [.androidUSB, .ricohGR, .cameraUSB]),
      .init(title: L("局域网共享"), kinds: [.smb, .webdavHTTPS, .nfs]),
      .init(
        title: L("网盘"),
        kinds: [
          .aliyunDrive, .quark, .baiduDrive, .drive115, .drive123, .oneDrive, .googleDrive,
          .dropbox,
        ]),
      .init(
        title: L("实验性网盘"),
        kinds: [.ucDrive, .tianyiDrive, .mobileCloud, .thunderDrive, .pikPak, .lanzou]),
      .init(
        title: L("对象存储"),
        kinds: [.s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2]),
    ]
  }

  static func matching(_ query: String) -> [ConnectionTypeGroup] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).folding(
      options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    guard !needle.isEmpty else { return groups }
    return groups.compactMap { group in
      let kinds = group.kinds.filter { kind in
        let text = kind.title + " " + caption(kind) + " " + aliases(kind)
        let latin =
          text.applyingTransform(.toLatin, reverse: false)?.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")) ?? text
        let initials = latin.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
          .compactMap(\.first).map(String.init).joined()
        return text.localizedCaseInsensitiveContains(needle) || latin.contains(needle)
          || latin.replacingOccurrences(of: " ", with: "").contains(needle)
          || initials.contains(needle)
      }
      return kinds.isEmpty ? nil : .init(title: group.title, kinds: kinds)
    }
  }

  static func caption(_ kind: ConnectionKind) -> String {
    switch kind {
    case .smb: L("Windows、Mac、NAS")
    case .webdav, .webdavHTTPS: L("网页文件服务")
    case .androidUSB, .androidWiFi: L("数据线或无线调试")
    case .ricohGR: L("读取照片与视频")
    case .cameraUSB: L("通过 USB 读取相机")
    case .nfs: L("网络文件共享")
    case .lanzou: L("浏览账号或分享链接")
    case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2: L("存储桶与对象")
    default: L("连接云端文件")
    }
  }

  private static func aliases(_ kind: ConnectionKind) -> String {
    switch kind {
    case .androidUSB, .androidWiFi: "android usb wifi azsj 安卓 手机"
    case .cameraUSB, .ricohGR: "camera photo xj 相机"
    case .smb: "smb windows mac nas gx 共享"
    case .webdav, .webdavHTTPS: "webdav https http dav 共享 gx"
    case .nfs: "nfs linux nas gx"
    case .aliyunDrive: "aliyun alipan a l y p alyp 网盘 wp"
    case .quark: "quark kk 夸克 网盘 wp"
    case .baiduDrive: "baidu bdwp 网盘 wp"
    case .drive115: "115 wp 网盘"
    case .drive123: "123 wp 网盘"
    case .oneDrive, .googleDrive, .dropbox, .ucDrive, .tianyiDrive, .mobileCloud, .thunderDrive,
      .pikPak, .lanzou:
      "cloud drive 网盘 wp"
    default: "s3 bucket storage dxcc 对象存储"
    }
  }

  static func movedSelection(_ selected: ConnectionKind?, offset: Int, query: String)
    -> ConnectionKind?
  {
    let kinds = matching(query).flatMap(\.kinds)
    guard !kinds.isEmpty else { return nil }
    guard let selected, let index = kinds.firstIndex(of: selected) else { return kinds.first }
    return kinds[min(max(index + offset, 0), kinds.count - 1)]
  }

  static func storagePreset(for kind: ConnectionKind) -> S3ServicePreset? {
    switch kind {
    case .s3: .amazonS3
    case .cloudflareR2: .cloudflareR2
    case .aliyunOSS: .aliyunOSS
    case .tencentCOS: .tencentCOS
    case .qiniuKodo: .qiniuKodo
    case .minIO: .minIO
    case .backblazeB2: .backblazeB2
    default: nil
    }
  }
}
