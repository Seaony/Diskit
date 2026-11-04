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
    let type = kind == .webdavHTTPS ? ConnectionKind.webdav.rawValue : kind.rawValue
    let palette = color.flatMap { colors.contains($0) ? $0 : nil } ?? defaults[kind] ?? "blue"
    return "TypeIcon-\(type)-\(palette)"
  }

  private static let colors: Set<String> = [
    "blue", "green", "orange", "red", "purple", "pink", "teal", "gray",
  ]
  private static let defaults: [ConnectionKind: String] = [
    .androidUSB: "green", .androidWiFi: "teal", .smb: "blue", .ricohGR: "gray",
    .cameraUSB: "gray", .webdav: "teal", .webdavHTTPS: "teal", .nfs: "blue",
    .aliyunDrive: "orange", .quark: "purple", .baiduDrive: "red", .drive115: "blue",
    .drive123: "teal", .oneDrive: "blue", .googleDrive: "green", .dropbox: "blue",
    .ucDrive: "orange", .tianyiDrive: "orange", .mobileCloud: "pink",
    .thunderDrive: "purple", .pikPak: "pink", .lanzou: "teal", .s3: "orange",
    .cloudflareR2: "orange", .aliyunOSS: "orange", .tencentCOS: "blue",
    .qiniuKodo: "red", .minIO: "pink", .backblazeB2: "green",
  ]
}
