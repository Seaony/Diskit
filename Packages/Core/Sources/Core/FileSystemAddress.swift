import Foundation

extension ConnectionKind {
  public var usesMount: Bool { usesSystemMount || fileSystemScheme != nil }

  public var fileSystemScheme: String? {
    switch self {
    case .smb, .webdav, .webdavHTTPS, .nfs, .ricohGR: nil
    case .androidUSB, .androidWiFi: "diskit-adb"
    case .cameraUSB: "diskit-camera"
    case .aliyunDrive: "diskit-aliyun"
    case .quark: "diskit-quark"
    case .baiduDrive: "diskit-baidu"
    case .tencentCOS: "diskit-cos"
    case .backblazeB2: "diskit-b2"
    case .cloudflareR2: "diskit-r2"
    case .googleDrive: "diskit-google"
    case .mobileCloud: "diskit-mobile"
    case .thunderDrive: "diskit-thunder"
    case .tianyiDrive: "diskit-tianyi"
    case .aliyunOSS: "diskit-oss"
    case .qiniuKodo: "diskit-kodo"
    default: "diskit-" + rawValue.lowercased()
    }
  }
}

public enum FileSystemAddress {
  public static var supportedSchemes: [String] {
    Array(Set(ConnectionKind.allCases.compactMap(\.fileSystemScheme))).sorted()
  }

  public static func url(for connection: Connection) throws -> URL {
    guard let scheme = connection.kind.fileSystemScheme else { throw RemoteError.unsupported }
    var components = URLComponents()
    components.scheme = scheme
    components.host = connection.id.uuidString.lowercased()
    guard let url = components.url else { throw RemoteError.invalidPath }
    return url
  }

  public static func connection(for url: URL, in connections: [Connection]) throws -> Connection {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.user == nil, components.password == nil, components.port == nil,
      components.query == nil, components.fragment == nil,
      components.path.isEmpty || components.path == "/",
      let host = components.host, let id = UUID(uuidString: host),
      let scheme = components.scheme?.lowercased(), supportedSchemes.contains(scheme)
    else { throw RemoteError.invalidPath }
    guard let connection = connections.first(where: { $0.id == id }) else {
      throw RemoteError.posix(ENOENT)
    }
    guard connection.kind.fileSystemScheme == scheme else { throw RemoteError.invalidPath }
    return connection
  }
}
