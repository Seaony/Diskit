import Core
import SwiftUI

struct TypeIcon: View {
  let kind: ConnectionKind
  var color: String? = nil
  let size: CGFloat

  var body: some View {
    Image(Self.assetName(kind: kind, color: color))
      .renderingMode(.original)
      .resizable()
      .interpolation(.high)
      .aspectRatio(contentMode: .fit)
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }

  static func assetName(kind: ConnectionKind, color: String?) -> String {
    // 同一种设备不同连接方式共用一套图标
    let type =
      switch kind {
      case .webdavHTTPS: ConnectionKind.webdav.rawValue
      case .androidMTP: ConnectionKind.androidUSB.rawValue
      default: kind.rawValue
      }
    let palette = color.flatMap { colors.contains($0) ? $0 : nil } ?? defaults[kind] ?? "blue"
    return "TypeIcon-\(type)-\(palette)"
  }

  private static let colors: Set<String> = [
    "blue", "green", "orange", "red", "purple", "pink", "teal", "gray",
  ]
  private static let defaults: [ConnectionKind: String] = [
    .androidUSB: "green", .androidWiFi: "teal", .androidMTP: "green", .smb: "blue",
    .cameraUSB: "gray", .webdav: "teal", .webdavHTTPS: "teal", .nfs: "blue",
    .quark: "purple",
    .ucDrive: "orange", .tianyiDrive: "orange", .mobileCloud: "pink",
    .thunderDrive: "purple", .pikPak: "pink", .lanzou: "teal", .s3: "orange",
    .cloudflareR2: "orange", .aliyunOSS: "orange", .tencentCOS: "blue",
    .qiniuKodo: "red", .minIO: "pink", .backblazeB2: "green",
  ]
}
