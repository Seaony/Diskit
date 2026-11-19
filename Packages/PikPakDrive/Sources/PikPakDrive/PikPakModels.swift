import Core
import Foundation

public struct PikPakAccount: Equatable, Sendable {
  public let userID: String
  public let nickname: String
  public let email: String
  public let total: Int64
  public let used: Int64

  public init(userID: String, nickname: String, email: String, total: Int64, used: Int64) {
    self.userID = userID
    self.nickname = nickname
    self.email = email
    self.total = total
    self.used = used
  }
}

struct StoredPikPakAuthorization: Codable, Sendable {
  var accessToken: String
  var refreshToken: String
  var expiresAt: TimeInterval
  var deviceID: String
  var userID: String
  var invalidated = false
}

struct PikPakToken: Decodable, Sendable {
  let accessToken: String
  let refreshToken: String
  let expiresIn: Int64
  let subject: String?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case expiresIn = "expires_in"
    case subject = "sub"
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    accessToken = try values.decode(String.self, forKey: .accessToken)
    refreshToken = try values.decode(String.self, forKey: .refreshToken)
    expiresIn = try values.decodeFlexibleInt64(forKey: .expiresIn)
    subject = try values.decodeIfPresent(String.self, forKey: .subject)
  }
}

struct PikPakUser: Decodable, Sendable {
  let subject: String?
  let name: String?
  let email: String?

  enum CodingKeys: String, CodingKey {
    case subject = "sub"
    case name
    case email
  }
}

struct PikPakAbout: Decodable, Sendable {
  struct Quota: Decodable, Sendable {
    let limit: Int64?
    let usage: Int64?

    enum CodingKeys: String, CodingKey {
      case limit
      case usage
    }

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      limit = try values.decodeFlexibleInt64IfPresent(forKey: .limit)
      usage = try values.decodeFlexibleInt64IfPresent(forKey: .usage)
    }
  }

  let quota: Quota?
}

struct PikPakFile: Decodable, Sendable {
  let id: String
  let name: String
  let kind: String
  let size: Int64?
  let modifiedTime: String?
  let createdTime: String?
  let parentID: String?
  let phase: String?
  let links: Links?
  // 在 Finder 里显示的名字：同目录重名时由列目录分配「名称 (2)」，否则就是 name
  var displayName: String

  enum CodingKeys: String, CodingKey {
    case id, name, kind, size, phase, links
    case modifiedTime = "modified_time"
    case createdTime = "created_time"
    case parentID = "parent_id"
  }

  struct Links: Decodable, Sendable {
    let original: Link?

    enum CodingKeys: String, CodingKey {
      case original = "application/octet-stream"
    }
  }

  struct Link: Decodable, Sendable {
    let url: URL
    let expire: String?

    var expiresAt: Date? {
      if let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first(where: { $0.name == "expire" })?.value
      {
        guard let seconds = Double(raw), seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
      }
      return expire.flatMap { RemoteTimestamp.parse($0) }
    }
  }

  init(
    id: String, name: String, kind: String, size: Int64?, modifiedTime: String?,
    createdTime: String?, parentID: String?, phase: String?, links: Links?
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.size = size
    self.modifiedTime = modifiedTime
    self.createdTime = createdTime
    self.parentID = parentID
    self.phase = phase
    self.links = links
    displayName = name
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    kind = try values.decode(String.self, forKey: .kind)
    size = try values.decodeFlexibleInt64IfPresent(forKey: .size)
    modifiedTime = try values.decodeIfPresent(String.self, forKey: .modifiedTime)
    createdTime = try values.decodeIfPresent(String.self, forKey: .createdTime)
    parentID = try values.decodeIfPresent(String.self, forKey: .parentID)
    phase = try values.decodeIfPresent(String.self, forKey: .phase)
    links = try values.decodeIfPresent(Links.self, forKey: .links)
    displayName = name
  }

  var isDirectory: Bool { kind == "drive#folder" }

  func item(at path: RemotePath) throws -> RemoteItem {
    guard !id.isEmpty, !name.isEmpty, !name.contains("/"), name != ".", name != "..",
      kind == "drive#file" || kind == "drive#folder"
    else { throw RemoteError.protocolError }
    if !isDirectory {
      guard let size, size >= 0 else { throw RemoteError.protocolError }
    }
    let timestamp = modifiedTime ?? createdTime
    guard let timestamp, let modified = RemoteTimestamp.parse(timestamp) else {
      throw RemoteError.protocolError
    }
    return RemoteItem(
      path: path, name: displayName, isDirectory: isDirectory,
      size: isDirectory ? Int64(0) : size!,
      modified: modified)
  }
}

struct PikPakFileList: Decodable, Sendable {
  let files: [PikPakFile]
  let nextPageToken: String?

  enum CodingKeys: String, CodingKey {
    case files
    case nextPageToken = "next_page_token"
  }
}

struct PikPakNewFile: Decodable, Sendable {
  let file: PikPakFile?
  let resumable: PikPakResumable?
  let task: PikPakTask?
}

struct PikPakResumable: Decodable, Sendable {
  let parameters: Parameters

  enum CodingKeys: String, CodingKey { case parameters = "params" }

  struct Parameters: Decodable, Sendable {
    let accessKeyID: String
    let accessKeySecret: String
    let bucket: String
    let key: String
    let securityToken: String

    enum CodingKeys: String, CodingKey {
      case accessKeyID = "access_key_id"
      case accessKeySecret = "access_key_secret"
      case bucket, key
      case securityToken = "security_token"
    }
  }
}

struct PikPakTask: Decodable, Sendable {
  let id: String
  let phase: String
  let progress: Int64?
  // 任务失败时 PikPak 写在这里的原因
  let message: String?

  enum CodingKeys: String, CodingKey { case id, phase, progress, message }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    phase = try values.decode(String.self, forKey: .phase)
    progress = try values.decodeFlexibleInt64IfPresent(forKey: .progress)
    message = (try? values.decodeIfPresent(String.self, forKey: .message))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct PikPakMutation: Decodable, Sendable {
  let taskID: String?

  enum CodingKeys: String, CodingKey { case taskID = "task_id" }
}

enum PikPakJSON {
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
}

extension KeyedDecodingContainer {
  fileprivate func decodeFlexibleInt64(forKey key: Key) throws -> Int64 {
    if let value = try? decode(Int64.self, forKey: key) { return value }
    if let value = try? decode(String.self, forKey: key), let parsed = Int64(value) {
      return parsed
    }
    throw DecodingError.dataCorruptedError(
      forKey: key, in: self, debugDescription: "Expected an integer or numeric string")
  }

  fileprivate func decodeFlexibleInt64IfPresent(forKey key: Key) throws -> Int64? {
    guard contains(key) else { return nil }
    guard try !decodeNil(forKey: key) else { return nil }
    return try decodeFlexibleInt64(forKey: key)
  }
}
