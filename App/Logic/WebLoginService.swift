import Core
import Foundation

enum WebLoginService: String, CaseIterable, Sendable {
  case quark, uc, tianyi, mobile, xunlei, lanzou

  var name: String {
    switch self {
    case .quark: L("夸克网盘")
    case .uc: L("UC 网盘")
    case .tianyi: L("天翼云盘")
    case .mobile: L("移动云盘")
    case .xunlei: L("迅雷云盘")
    case .lanzou: L("蓝奏云")
    }
  }

  var loginURL: URL {
    switch self {
    case .quark: URL(string: "https://pan.quark.cn/")!
    case .uc: URL(string: "https://drive.uc.cn/")!
    case .tianyi: URL(string: "https://cloud.189.cn/web/login.html")!
    case .mobile: URL(string: "https://yun.139.com/w/")!
    case .xunlei: URL(string: "https://pan.xunlei.com/")!
    case .lanzou: URL(string: "https://pc.woozooo.com/mydisk.php")!
    }
  }

  var domain: String {
    switch self {
    case .quark: "quark.cn"
    case .uc: "uc.cn"
    case .tianyi: "189.cn"
    case .mobile: "yun.139.com"
    case .xunlei: "xunlei.com"
    case .lanzou: "woozooo.com"
    }
  }

  func allows(_ url: URL?) -> Bool {
    guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
      return false
    }
    return host == domain || host.hasSuffix("." + domain)
  }
}
