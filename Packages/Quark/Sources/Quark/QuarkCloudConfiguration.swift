import Core
import Foundation

public struct QuarkCloudConfiguration: Sendable, Equatable {
  public let service: QuarkCloudService
  public let cookieDomain: String
  public let loginURL: URL
  public let refererURL: String
  public let accountURL: URL
  public let apiBase: String
  public let clientParameter: String
  public let userAgent: String

  public static let quark = QuarkCloudConfiguration(
    service: .quark, cookieDomain: "quark.cn",
    loginURL: URL(string: "https://pan.quark.cn/")!,
    refererURL: "https://pan.quark.cn/",
    accountURL: URL(string: "https://pan.quark.cn/account/info")!,
    apiBase: "https://drive.quark.cn/1/clouddrive", clientParameter: "ucpro",
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
  )

  public static let uc = QuarkCloudConfiguration(
    service: .uc, cookieDomain: "uc.cn",
    loginURL: URL(string: "https://drive.uc.cn/")!,
    refererURL: "https://drive.uc.cn/",
    accountURL: URL(string: "https://drive.uc.cn/account/info")!,
    apiBase: "https://pc-api.uc.cn/1/clouddrive", clientParameter: "UCBrowser",
    userAgent:
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
  )
}
