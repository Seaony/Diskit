import Foundation

public enum ConnectionKind: String, Codable, CaseIterable, Sendable {
  case androidUSB, androidWiFi, smb, ricohGR, aliyunDrive, quark
  case cameraUSB
  case webdav, webdavHTTPS, nfs
  case s3, cloudflareR2, aliyunOSS, tencentCOS, qiniuKodo, minIO, backblazeB2
  case baiduDrive, drive115, drive123, oneDrive, googleDrive, dropbox
  case ucDrive, tianyiDrive, mobileCloud, thunderDrive, pikPak, lanzou
  public var usesSystemMount: Bool {
    switch self {
    case .smb, .webdav, .webdavHTTPS, .nfs: true
    default: false
    }
  }
  public var usesStoredRemoteSecret: Bool {
    switch self {
    case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2,
      .lanzou, .mobileCloud, .thunderDrive:
      true
    default:
      false
    }
  }
}

public struct Connection: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var kind: ConnectionKind
  public var name: String
  public var color: String
  public var autoMount: Bool
  public var openInFinderAfterMount: Bool
  public var order: Int
  public var params: [String: String]
  public init(
    id: UUID = UUID(), kind: ConnectionKind = .smb, name: String = "", color: String = "blue",
    autoMount: Bool = false, openInFinderAfterMount: Bool = true, order: Int = 0,
    params: [String: String] = [:]
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.color = color
    self.autoMount = autoMount
    self.openInFinderAfterMount = openInFinderAfterMount
    self.order = order
    self.params = params
  }
  public var passwordKey: String { "\(id.uuidString).password" }
  public var usesFileSystemCache: Bool {
    switch kind {
    case .androidUSB, .androidWiFi, .ricohGR, .cameraUSB, .aliyunDrive, .quark, .baiduDrive,
      .drive115, .drive123, .oneDrive, .googleDrive, .dropbox, .ucDrive, .tianyiDrive,
      .mobileCloud, .thunderDrive, .pikPak, .lanzou:
      true
    case .smb, .webdav, .webdavHTTPS, .nfs, .s3, .cloudflareR2, .aliyunOSS, .tencentCOS,
      .qiniuKodo, .minIO, .backblazeB2:
      false
    }
  }
}

public struct ConnectionDocument: Codable, Sendable {
  public var version = 1
  public var connections: [Connection]
  public init(connections: [Connection]) { self.connections = connections }
}

public enum ConnectionError: Error, Equatable, LocalizedError {
  case invalidFields, unsupportedVersion, authentication, timeout, missingShare, notImplemented,
    busy
  case system(Int32)
  public var errorDescription: String? {
    switch self {
    case .invalidFields: return L("请检查带星号的必填项")
    case .unsupportedVersion: return L("配置来自更新版本，请升级 Kayoi")
    case .authentication: return L("用户名或密码错误")
    case .timeout: return L("连接超时，请检查主机地址和网络")
    case .missingShare: return L("找不到该共享，请检查共享名和访问权限")
    case .notImplemented: return L("此类型暂时不可用")
    case .busy: return L("连接正在处理，请稍后重试")
    case .system: return L("系统无法完成操作，请稍后重试")
    }
  }
  public static func status(_ value: Int32) -> ConnectionError {
    switch value {
    case EAUTH, EACCES, EPERM, -6603, -5000: .authentication
    case ETIMEDOUT: .timeout
    case ENOENT, -5998: .missingShare
    default: .system(value)
    }
  }
}

public struct ConnectionRepository: Sendable {
  public let store: ConfigurationStore
  public init(location: any StorageLocation = LocalStorageLocation()) {
    store = ConfigurationStore(location: location)
  }
  public func load() throws -> [Connection] {
    guard let data = try store.read() else { return [] }
    let document = try JSONDecoder().decode(ConnectionDocument.self, from: data)
    guard document.version == 1 else { throw ConnectionError.unsupportedVersion }
    return document.connections.sorted { $0.order < $1.order }
  }
  public func save(_ connections: [Connection]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try store.write(encoder.encode(ConnectionDocument(connections: connections)))
  }
}
