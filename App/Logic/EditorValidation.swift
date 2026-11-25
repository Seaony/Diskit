import Core
import Foundation
import S3Drive

enum EditorValidation {
  static func requiredFields(draft: Connection, pairingCode: String, guest: Bool, forceLogin: Bool)
    -> [String]
  {
    switch draft.kind {
    case .androidUSB, .cameraUSB: ["name", "device"]
    case .androidWiFi:
      draft.params["guid"] == nil ? ["name", "pairingID", "pairingCode"] : ["name"]
    case .smb: guest ? ["name", "host", "share"] : ["name", "host", "username", "share"]
    case .webdav, .webdavHTTPS: ["name", "url"]
    case .nfs: ["name", "host", "path"]
    case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2:
      ["name", "endpoint", "bucket", "accessKey", "password"]
    case .pikPak:
      forceLogin || draft.params["accountReady"] != "true"
        ? ["name", "username", "password"] : ["name"]
    case .tianyiDrive: draft.params["scope"] == "family" ? ["name", "familyID"] : ["name"]
    case .lanzou: draft.params["authMode"] == "share" ? ["name", "shareURL"] : ["name"]
    default: ["name"]
    }
  }

  static func label(_ field: String) -> String {
    switch field {
    case "name": L("显示名称")
    case "device", "serial": L("设备")
    case "pairingID": L("配对设备")
    case "pairingCode": L("六位配对码")
    case "host": L("主机地址")
    case "share": L("共享名")
    case "username": L("用户名")
    case "url": L("服务器地址")
    case "path": L("导出路径")
    case "endpoint": L("服务地址")
    case "bucket": L("存储桶")
    case "accessKey": L("访问密钥")
    case "password": L("密码或私密密钥")
    case "familyID": L("家庭云")
    case "shareURL": L("分享链接")
    default: L("必填信息")
    }
  }

  static func addressIssue(_ draft: Connection) -> String? {
    let key: String
    switch draft.kind {
    case .webdav, .webdavHTTPS: key = "url"
    case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2:
      key = "endpoint"
    case .lanzou where draft.params["authMode"] == "share": key = "shareURL"
    default: return nil
    }
    let raw = draft.params[key] ?? ""
    guard !raw.isEmpty else { return nil }
    if raw.localizedCaseInsensitiveContains("ACCOUNT_ID") || raw.contains("USERNAME") {
      return L("请把地址模板替换为自己的账号和地址")
    }
    guard let components = URLComponents(string: raw), let host = components.host, !host.isEmpty,
      ["https", "http"].contains(components.scheme?.lowercased() ?? ""), components.user == nil,
      components.password == nil,
      !raw.contains(where: \.isWhitespace)
    else { return L("请填写完整的服务器地址，例如 https://nas.local/dav/") }
    if key == "endpoint", let endpoint = components.url, !S3EndpointPolicy.allows(endpoint) {
      return L("远程对象存储需要使用 HTTPS；HTTP 仅适用于本地网络地址")
    }
    if draft.kind == .lanzou && components.scheme?.lowercased() != "https" {
      return L("分享链接需要使用 HTTPS")
    }
    return nil
  }
}
