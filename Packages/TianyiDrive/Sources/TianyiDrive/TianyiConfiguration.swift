import Core
import Foundation

public enum TianyiStorageScope: Equatable, Sendable {
  case personal
  case family(familyID: String)

  public var rootFolderID: String {
    switch self {
    case .personal: "-11"
    case .family: ""
    }
  }

  public var familyID: String? {
    guard case .family(let familyID) = self else { return nil }
    return familyID
  }

  public var isFamily: Bool {
    if case .family = self { return true }
    return false
  }
}

public struct TianyiConfiguration: Sendable, Equatable {
  public let webBaseURL: URL
  public let apiBaseURL: URL
  public let uploadBaseURL: URL
  public let cookieDomain: String
  public let scope: TianyiStorageScope
  public let pageSize: Int
  public let appID: String
  public let clientType: String
  public let pcClientType: String
  public let version: String
  public let channelID: String
  public let returnURL: URL
  public let userAgent: String

  public static let personal = TianyiConfiguration(scope: .personal)

  public static func family(familyID: String, pageSize: Int = 1000) -> TianyiConfiguration {
    TianyiConfiguration(scope: .family(familyID: familyID), pageSize: pageSize)
  }

  public init(
    scope: TianyiStorageScope, pageSize: Int = 1000
  ) {
    webBaseURL = URL(string: "https://cloud.189.cn")!
    apiBaseURL = URL(string: "https://api.cloud.189.cn")!
    uploadBaseURL = URL(string: "https://upload.cloud.189.cn")!
    cookieDomain = "cloud.189.cn"
    self.scope = scope
    self.pageSize = max(1, pageSize)
    appID = "9317140619"
    clientType = "10020"
    pcClientType = "TELEPC"
    version = "7.2.4.0"
    channelID = "web_cloud.189.cn"
    returnURL = URL(
      string: "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html")!
    userAgent =
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      + "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
  }
}

public struct TianyiAccount: Sendable, Equatable {
  public let scope: TianyiStorageScope
  public let userID: String
  public let displayName: String
  public let total: Int64
  public let used: Int64

  public init(
    scope: TianyiStorageScope, userID: String, displayName: String, total: Int64, used: Int64
  ) {
    self.scope = scope
    self.userID = userID
    self.displayName = displayName
    self.total = total
    self.used = used
  }
}

public struct TianyiFamilySpace: Sendable, Equatable {
  public let familyID: String
  public let name: String

  public init(familyID: String, name: String) {
    self.familyID = familyID
    self.name = name
  }
}
