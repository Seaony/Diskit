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
import S3Drive
import TianyiDrive

enum RemoteProviderFactory {
  static func make(
    for connection: Connection, secrets: any SecretStore = SharedKeychainStore(),
    info: [String: Any]
  ) async throws -> any RemoteFileProvider {
    let secrets = RecoverableSecretStore(base: secrets)
    func value(_ key: String) -> String { info[key] as? String ?? "" }
    func savedSecret() throws -> String {
      try secrets.read(connection.passwordKey).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    func oauthSession() throws -> OAuthSession {
      guard let configuration = oauthConfiguration(for: connection.kind, info: info),
        configuration.isConfigured
      else { throw OAuthDriveError.configuration }
      return OAuthSession(
        configuration: configuration,
        secretKey: "\(connection.id.uuidString).oauth.\(connection.kind.rawValue)", secrets: secrets
      )
    }
    switch connection.kind {
    case .androidUSB, .androidWiFi:
      return try await ADBProviderFactory.make(
        for: connection, identity: ADBIdentity(store: secrets))
    case .cameraUSB:
      return try await CameraUSBProvider.make(
        identifier: connection.params["deviceID"] ?? connection.params["serial"] ?? "")
    case .aliyunDrive:
      return AliyunProvider(
        session: AliyunSession(
          secretKey: "\(connection.id.uuidString).oauth", secrets: secrets,
          configuration: AliyunConfiguration(
            clientID: value("ALIYUN_CLIENT_ID"), clientSecret: value("ALIYUN_CLIENT_SECRET"),
            redirectURI: value("ALIYUN_REDIRECT_URI"))))
    case .quark, .ucDrive:
      return QuarkProvider(
        session: QuarkSession(
          secretKey: "\(connection.id.uuidString).cookie", secrets: secrets,
          configuration: connection.kind == .ucDrive ? .uc : .quark))
    case .baiduDrive:
      return BaiduDriveProvider(
        configuration: BaiduDriveConfiguration(
          rootPath: info["BAIDU_ROOT_PATH"] as? String ?? "apps/Kayoi",
          appID: value("BAIDU_APP_ID")),
        session: try oauthSession())
    case .drive115:
      return Drive115Provider(session: try oauthSession())
    case .drive123:
      return Drive123Provider(session: try oauthSession())
    case .oneDrive:
      return OneDriveProvider(session: try oauthSession())
    case .googleDrive:
      return GoogleDriveProvider(session: try oauthSession())
    case .dropbox:
      return DropboxProvider(session: try oauthSession())
    case .pikPak:
      return PikPakProvider(
        session: PikPakSession(
          secretKey: "\(connection.id.uuidString).oauth.pikPak", secrets: secrets))
    case .tianyiDrive:
      let configuration =
        connection.params["scope"] == "family"
        ? TianyiConfiguration.family(familyID: connection.params["familyID"] ?? "")
        : TianyiConfiguration.personal
      return TianyiProvider(
        session: TianyiSession(
          secretKey: "\(connection.id.uuidString).oauth.tianyiDrive", secrets: secrets,
          configuration: configuration))
    case .lanzou:
      let secret = try savedSecret()
      let authentication: LanzouAuthentication
      if connection.params["authMode"] == "share" {
        guard let url = URL(string: connection.params["shareURL"] ?? "") else {
          throw ConnectionError.invalidFields
        }
        authentication = .share(url: url, password: secret.isEmpty ? nil : secret)
      } else {
        authentication = .accountCookie(secret)
      }
      let configuration = try LanzouConfiguration(authentication: authentication)
      let key = connection.passwordKey
      return LanzouProvider(
        session: LanzouSession(
          configuration: configuration,
          persistAccountCookie: { cookie in
            try secrets.write(Data(cookie.utf8), for: key)
          }))
    case .mobileCloud:
      return MobileCloudProvider(
        session: MobileCloudSession(
          credentials: MobileCloudCredentials(
            phone: connection.params["phone"] ?? "", token: try savedSecret(),
            userDomainID: connection.params["userDomainID"])))
    case .thunderDrive:
      return XunleiProvider(
        session: XunleiSession(
          credentials: XunleiCredentials(accessToken: try savedSecret())))
    case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2:
      guard let endpoint = URL(string: connection.params["endpoint"] ?? "") else {
        throw ConnectionError.invalidFields
      }
      return S3Provider(
        configuration: S3Configuration(
          endpoint: endpoint, region: connection.params["region"] ?? "us-east-1",
          bucket: connection.params["bucket"] ?? "",
          accessKey: connection.params["accessKey"] ?? "", secretKey: try savedSecret(),
          pathStyle: connection.params["pathStyle"] != "false"))
    case .smb, .webdav, .webdavHTTPS, .nfs, .ricohGR:
      throw ConnectionError.notImplemented
    }
  }

  private static func oauthConfiguration(for kind: ConnectionKind, info: [String: Any])
    -> OAuthConfiguration?
  {
    func value(_ key: String) -> String { info[key] as? String ?? "" }
    switch kind {
    case .baiduDrive:
      return OAuthConfiguration(
        clientID: value("BAIDU_CLIENT_ID"), clientSecret: value("BAIDU_CLIENT_SECRET"),
        authorizationURL: URL(string: "https://openapi.baidu.com/oauth/2.0/authorize")!,
        tokenURL: URL(string: "https://openapi.baidu.com/oauth/2.0/token")!,
        redirectURI: value("BAIDU_REDIRECT_URI"), scopes: ["basic", "netdisk"],
        scopeSeparator: ",", tokenRequestMethod: "GET", tokenRequestPlacement: .query)
    case .drive115:
      return OAuthConfiguration(
        clientID: value("DRIVE115_CLIENT_ID"), clientSecret: value("DRIVE115_CLIENT_SECRET"),
        authorizationURL: URL(string: "https://passportapi.115.com/open/authorize")!,
        tokenURL: URL(string: "https://passportapi.115.com/open/authCodeToToken")!,
        refreshTokenURL: URL(string: "https://passportapi.115.com/open/refreshToken")!,
        redirectURI: value("DRIVE115_REDIRECT_URI"), scopes: [],
        tokenResponseDataKey: "data", refreshGrantIncludesClientCredentials: false)
    case .drive123:
      return OAuthConfiguration(
        clientID: value("DRIVE123_CLIENT_ID"), clientSecret: value("DRIVE123_CLIENT_SECRET"),
        authorizationURL: URL(string: "https://yun.123pan.com/auth")!,
        tokenURL: URL(string: "https://open-api.123pan.com/api/v1/oauth2/access_token")!,
        redirectURI: value("DRIVE123_REDIRECT_URI"),
        scopes: ["user:base", "file:all:read", "file:all:write"], scopeSeparator: ",")
    case .oneDrive:
      return OAuthConfiguration(
        clientID: value("ONEDRIVE_CLIENT_ID"), clientSecret: "",
        authorizationURL: URL(
          string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
        tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
        redirectURI: value("ONEDRIVE_REDIRECT_URI"),
        scopes: ["offline_access", "User.Read", "Files.ReadWrite"], usesPKCE: true)
    case .googleDrive:
      return OAuthConfiguration(
        clientID: value("GOOGLE_CLIENT_ID"), clientSecret: "",
        authorizationURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
        redirectURI: GoogleDesktopOAuth.redirectURI(clientID: value("GOOGLE_CLIENT_ID")),
        scopes: ["openid", "email", "profile", "https://www.googleapis.com/auth/drive"],
        additionalAuthorizationItems: ["access_type": "offline", "prompt": "consent"],
        usesPKCE: true)
    case .dropbox:
      return OAuthConfiguration(
        clientID: value("DROPBOX_CLIENT_ID"), clientSecret: "",
        authorizationURL: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
        tokenURL: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
        redirectURI: value("DROPBOX_REDIRECT_URI"),
        scopes: [
          "account_info.read", "files.content.read", "files.content.write",
          "files.metadata.read", "files.metadata.write",
        ],
        additionalAuthorizationItems: ["token_access_type": "offline"], usesPKCE: true)
    default:
      return nil
    }
  }
}
