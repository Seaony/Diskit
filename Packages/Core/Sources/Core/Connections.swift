import Foundation

public enum ConnectionKind: String, Codable, CaseIterable, Sendable {
  case androidUSB, androidWiFi, smb, ricohGR, aliyunDrive, quark
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
    case .invalidFields: return L("请填写名称、主机、用户名和共享名")
    case .unsupportedVersion: return L("配置来自更新版本，请升级 Kayoi")
    case .authentication: return L("用户名或密码错误")
    case .timeout: return L("连接超时，请检查主机地址和网络")
    case .missingShare: return L("找不到该共享，请检查共享名和访问权限")
    case .notImplemented: return L("此类型将在后续里程碑提供")
    case .busy: return L("连接正在处理，请稍后重试")
    case .system(let code): return String(format: L("系统操作失败（%d）"), code)
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

public func L(_ value: String) -> String { NSLocalizedString(value, bundle: .main, comment: "") }

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
