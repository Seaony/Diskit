import ADB
import CameraUSB
import ChinaWebDrive
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
    func savedSecret() throws -> String {
      try secrets.read(connection.passwordKey).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    switch connection.kind {
    case .androidUSB, .androidWiFi:
      return try await ADBProviderFactory.make(
        for: connection, identity: ADBIdentity(store: secrets))
    case .cameraUSB:
      return try await CameraUSBProvider.make(
        identifier: connection.params["deviceID"] ?? connection.params["serial"] ?? "")
    case .quark, .ucDrive:
      return QuarkProvider(
        session: QuarkSession(
          secretKey: "\(connection.id.uuidString).cookie", secrets: secrets,
          configuration: connection.kind == .ucDrive ? .uc : .quark))
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
    case .smb, .webdav, .webdavHTTPS, .nfs:
      throw ConnectionError.notImplemented
    }
  }
}
