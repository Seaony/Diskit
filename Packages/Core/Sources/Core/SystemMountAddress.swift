import Foundation

public enum SystemMountAddress {
  public static func url(for connection: Connection) throws -> URL {
    switch connection.kind {
    case .smb:
      return try SMBAddress.url(
        host: connection.params["host"] ?? "",
        user: connection.params["username"],
        share: connection.params["share"])
    case .webdav, .webdavHTTPS:
      return try url(
        scheme: connection.kind == .webdavHTTPS ? "https" : "http",
        address: connection.params["url"] ?? "",
        path: nil)
    case .nfs:
      return try url(
        scheme: "nfs", address: connection.params["host"] ?? "",
        path: connection.params["path"])
    default:
      throw ConnectionError.invalidFields
    }
  }

  public static func matches(connection: Connection, source: String, type: String) -> Bool {
    guard let expectedType = fileSystemType(for: connection.kind), type == expectedType,
      let expected = try? url(for: connection)
    else { return false }
    if connection.kind == .nfs, !source.lowercased().hasPrefix("nfs:") {
      let parts = source.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { return false }
      return parts[0].lowercased() == expected.host?.lowercased()
        && normalizedPath(parts[1].hasPrefix("/") ? String(parts[1]) : "/" + parts[1])
          == normalizedPath(expected.path)
    }
    let normalizedSource =
      source.lowercased().hasPrefix(expected.scheme!.lowercased() + ":")
      ? source : expected.scheme! + ":" + source
    guard let actual = URLComponents(string: normalizedSource) else { return false }
    return actual.host?.lowercased() == expected.host?.lowercased()
      && normalizedPath(actual.path) == normalizedPath(expected.path)
  }

  private static func url(scheme: String, address: String, path: String?) throws -> URL {
    let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw ConnectionError.invalidFields }
    if let components = URLComponents(string: value),
      let valueScheme = components.scheme?.lowercased()
    {
      guard valueScheme == scheme, components.host != nil, components.user == nil else {
        throw ConnectionError.invalidFields
      }
      return components.url!
    }
    guard !value.contains(where: { $0.isWhitespace || "/@?#".contains($0) }) else {
      throw ConnectionError.invalidFields
    }
    var components = URLComponents()
    components.scheme = scheme
    components.host = value
    components.path = path.map { $0.hasPrefix("/") ? $0 : "/" + $0 } ?? ""
    guard let url = components.url else { throw ConnectionError.invalidFields }
    return url
  }

  private static func fileSystemType(for kind: ConnectionKind) -> String? {
    switch kind {
    case .smb: "smbfs"
    case .webdav, .webdavHTTPS: "webdav"
    case .nfs: "nfs"
    default: nil
    }
  }

  private static func normalizedPath(_ path: String) -> String {
    let value = path.isEmpty ? "/" : path.precomposedStringWithCanonicalMapping
    return value.count > 1 && value.hasSuffix("/") ? String(value.dropLast()) : value
  }
}
