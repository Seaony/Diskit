import ADB
import AliyunDrive
import CameraUSB
import ChinaWebDrive
import CloudDrive
import Core
import Foundation
import LanzouDrive
import PikPakDrive
import Quark
import RicohGR
import S3Drive
import Synchronization
import TianyiDrive

enum CLIProviderFactory {
  static func make(_ connection: Connection, values: CLIEnvironment, secrets: any SecretStore)
    async throws -> any RemoteFileProvider
  {
    func environment(_ name: String, fallback: String = "") -> String {
      values.value(name, fallback: fallback)
    }
    func savedSecret(_ value: Connection) throws -> String {
      try secrets.read(value.passwordKey).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    func oauthKey(_ value: Connection) -> String {
      "\(value.id.uuidString).oauth.\(value.kind.rawValue)"
    }
    let provider: any RemoteFileProvider
    switch connection.kind {
    case .androidUSB, .androidWiFi: provider = try await ADBProviderFactory.make(for: connection)
    case .ricohGR:
      provider = try await RicohProvider.make(serial: connection.params["serial"] ?? "")
    case .cameraUSB:
      provider = try await CameraUSBProvider.make(identifier: connection.params["serial"] ?? "")
    case .aliyunDrive:
      provider = AliyunProvider(
        session: AliyunSession(
          secretKey: "\(connection.id.uuidString).oauth", secrets: secrets,
          configuration: AliyunConfiguration()))
    case .quark:
      provider = QuarkProvider(
        session: QuarkSession(
          secretKey: "\(connection.id.uuidString).cookie", secrets: secrets, configuration: .quark))
    case .ucDrive:
      provider = QuarkProvider(
        session: QuarkSession(
          secretKey: "\(connection.id.uuidString).cookie", secrets: secrets, configuration: .uc))
    case .baiduDrive:
      provider = BaiduDriveProvider(
        configuration: BaiduDriveConfiguration(
          rootPath: environment("BAIDU_ROOT_PATH", fallback: "apps/Kayoi"),
          appID: environment("BAIDU_APP_ID")),
        session: OAuthSession(
          configuration: oauthConfiguration(.baiduDrive, values: values),
          secretKey: oauthKey(connection), secrets: secrets))
    case .drive115:
      provider = Drive115Provider(
        session: OAuthSession(
          configuration: oauthConfiguration(.drive115, values: values),
          secretKey: oauthKey(connection), secrets: secrets))
    case .drive123:
      provider = Drive123Provider(
        session: OAuthSession(
          configuration: oauthConfiguration(.drive123, values: values),
          secretKey: oauthKey(connection), secrets: secrets))
    case .oneDrive:
      provider = OneDriveProvider(
        session: OAuthSession(
          configuration: oauthConfiguration(.oneDrive, values: values),
          secretKey: oauthKey(connection), secrets: secrets))
    case .googleDrive:
      provider = GoogleDriveProvider(
        session: OAuthSession(
          configuration: oauthConfiguration(.googleDrive, values: values),
          secretKey: oauthKey(connection), secrets: secrets))
    case .dropbox:
      provider = DropboxProvider(
        session: OAuthSession(
          configuration: oauthConfiguration(.dropbox, values: values),
          secretKey: oauthKey(connection), secrets: secrets))
    case .pikPak:
      provider = PikPakProvider(
        session: PikPakSession(
          secretKey: "\(connection.id.uuidString).oauth.pikPak", secrets: secrets))
    case .tianyiDrive:
      let configuration =
        connection.params["scope"] == "family"
        ? TianyiConfiguration.family(familyID: connection.params["familyID"] ?? "")
        : TianyiConfiguration.personal
      provider = TianyiProvider(
        session: TianyiSession(
          secretKey: "\(connection.id.uuidString).oauth.tianyiDrive", secrets: secrets,
          configuration: configuration))
    case .lanzou:
      let secret = try savedSecret(connection)
      let authentication: LanzouAuthentication
      if connection.params["authMode"] == "share" {
        guard let url = URL(string: connection.params["shareURL"] ?? "") else {
          throw ConnectionError.invalidFields
        }
        authentication = .share(url: url, password: secret.isEmpty ? nil : secret)
      } else {
        authentication = .accountCookie(secret)
      }
      provider = LanzouProvider(
        configuration: try LanzouConfiguration(authentication: authentication))
    case .mobileCloud:
      provider = MobileCloudProvider(
        session: MobileCloudSession(
          credentials: MobileCloudCredentials(
            phone: connection.params["phone"] ?? "", token: try savedSecret(connection),
            userDomainID: connection.params["userDomainID"])))
    case .thunderDrive:
      provider = XunleiProvider(
        session: XunleiSession(
          credentials: XunleiCredentials(accessToken: try savedSecret(connection))))
    case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2:
      guard let endpoint = URL(string: connection.params["endpoint"] ?? "") else {
        throw ConnectionError.invalidFields
      }
      let secret =
        try secrets.read(connection.passwordKey).map {
          String(decoding: $0, as: UTF8.self)
        } ?? ""
      provider = S3Provider(
        configuration: S3Configuration(
          endpoint: endpoint, region: connection.params["region"] ?? "us-east-1",
          bucket: connection.params["bucket"] ?? "",
          accessKey: connection.params["accessKey"] ?? "",
          secretKey: secret, pathStyle: connection.params["pathStyle"] != "false"))
    default: throw ConnectionError.notImplemented
    }
    return provider
  }
  static func oauthConfiguration(_ kind: ConnectionKind, values: CLIEnvironment)
    -> OAuthConfiguration
  {
    switch kind {
    case .baiduDrive:
      return OAuthConfiguration(
        clientID: values.value("BAIDU_CLIENT_ID"),
        clientSecret: values.value("BAIDU_CLIENT_SECRET"),
        authorizationURL: URL(string: "https://openapi.baidu.com/oauth/2.0/authorize")!,
        tokenURL: URL(string: "https://openapi.baidu.com/oauth/2.0/token")!,
        redirectURI: values.value("BAIDU_REDIRECT_URI"),
        scopes: ["basic", "netdisk"], scopeSeparator: ",",
        tokenRequestMethod: "GET", tokenRequestPlacement: .query)
    case .drive115:
      return OAuthConfiguration(
        clientID: values.value("DRIVE115_CLIENT_ID"),
        clientSecret: values.value("DRIVE115_CLIENT_SECRET"),
        authorizationURL: URL(string: "https://passportapi.115.com/open/authorize")!,
        tokenURL: URL(string: "https://passportapi.115.com/open/authCodeToToken")!,
        refreshTokenURL: URL(string: "https://passportapi.115.com/open/refreshToken")!,
        redirectURI: values.value("DRIVE115_REDIRECT_URI"), scopes: [],
        tokenResponseDataKey: "data", refreshGrantIncludesClientCredentials: false)
    case .drive123:
      return OAuthConfiguration(
        clientID: values.value("DRIVE123_CLIENT_ID"),
        clientSecret: values.value("DRIVE123_CLIENT_SECRET"),
        authorizationURL: URL(string: "https://yun.123pan.com/auth")!,
        tokenURL: URL(string: "https://open-api.123pan.com/api/v1/oauth2/access_token")!,
        redirectURI: values.value("DRIVE123_REDIRECT_URI"),
        scopes: ["user:base", "file:all:read", "file:all:write"], scopeSeparator: ",")
    case .oneDrive:
      return OAuthConfiguration(
        clientID: values.value("ONEDRIVE_CLIENT_ID"),
        clientSecret: "",
        authorizationURL: URL(
          string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
        tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
        redirectURI: values.value("ONEDRIVE_REDIRECT_URI"),
        scopes: ["offline_access", "User.Read", "Files.ReadWrite"], usesPKCE: true)
    case .googleDrive:
      return OAuthConfiguration(
        clientID: values.value("GOOGLE_CLIENT_ID"),
        clientSecret: "",
        authorizationURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
        redirectURI: GoogleDesktopOAuth.redirectURI(clientID: values.value("GOOGLE_CLIENT_ID")),
        scopes: ["openid", "email", "profile", "https://www.googleapis.com/auth/drive"],
        additionalAuthorizationItems: ["access_type": "offline", "prompt": "consent"],
        usesPKCE: true)
    case .dropbox:
      return OAuthConfiguration(
        clientID: values.value("DROPBOX_CLIENT_ID"),
        clientSecret: "",
        authorizationURL: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
        tokenURL: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
        redirectURI: values.value("DROPBOX_REDIRECT_URI"),
        scopes: [
          "account_info.read", "files.content.read", "files.content.write",
          "files.metadata.read", "files.metadata.write",
        ],
        additionalAuthorizationItems: ["token_access_type": "offline"], usesPKCE: true)
    default:
      return OAuthConfiguration(
        clientID: "", clientSecret: "",
        authorizationURL: URL(string: "https://example.invalid/authorize")!,
        tokenURL: URL(string: "https://example.invalid/token")!,
        redirectURI: "", scopes: [])
    }
  }
}
