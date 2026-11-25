import ADB
import CameraUSB
import ChinaWebDrive
import Core
import Foundation
import LanzouDrive
import PikPakDrive
import Quark
import S3Drive
import Synchronization
import TianyiDrive

enum CLIProviderFactory {
  static func make(_ connection: Connection, values: CLIEnvironment, secrets: any SecretStore)
    async throws -> any RemoteFileProvider
  {
    func savedSecret(_ value: Connection) throws -> String {
      try secrets.read(value.passwordKey).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    let provider: any RemoteFileProvider
    switch connection.kind {
    case .androidUSB, .androidWiFi: provider = try await ADBProviderFactory.make(for: connection)
    case .cameraUSB:
      provider = try await CameraUSBProvider.make(identifier: connection.params["serial"] ?? "")
    case .quark:
      provider = QuarkProvider(
        session: QuarkSession(
          secretKey: "\(connection.id.uuidString).cookie", secrets: secrets, configuration: .quark))
    case .ucDrive:
      provider = QuarkProvider(
        session: QuarkSession(
          secretKey: "\(connection.id.uuidString).cookie", secrets: secrets, configuration: .uc))
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
}
