import Core
import Foundation

struct TianyiNode: Sendable {
  let id: String
  let name: String
  let isDirectory: Bool
  let size: Int64
  let modified: Date

  func item(at path: RemotePath) -> RemoteItem {
    RemoteItem(
      path: path, name: name, isDirectory: isDirectory, size: size, modified: modified)
  }
}

struct TianyiFileList: Decodable, Sendable {
  let fileListAO: Page?

  struct Page: Decodable, Sendable {
    let count: Int?
    let fileList: [TianyiFile]?
    let folderList: [TianyiFolder]?
  }

  struct TianyiFile: Decodable, Sendable {
    let id: TianyiString
    let name: String
    let size: Int64?
    let lastOpTime: String?
    let createDate: String?

    enum CodingKeys: String, CodingKey {
      case id, name, size, lastOpTime, createDate
    }

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      id = try values.decode(TianyiString.self, forKey: .id)
      name = try values.decode(String.self, forKey: .name)
      size = try values.decodeIfPresent(Int64.self, forKey: .size)
      lastOpTime = try values.decodeIfPresent(String.self, forKey: .lastOpTime)
      createDate = try values.decodeIfPresent(String.self, forKey: .createDate)
    }

    var node: TianyiNode {
      TianyiNode(
        id: id.value, name: TianyiName.normalize(name), isDirectory: false,
        size: max(0, size ?? 0),
        modified: TianyiDate.parse(lastOpTime) ?? TianyiDate.parse(createDate) ?? .distantPast)
    }
  }

  struct TianyiFolder: Decodable, Sendable {
    let id: TianyiString
    let name: String
    let lastOpTime: String?
    let createDate: String?

    enum CodingKeys: String, CodingKey {
      case id, name, lastOpTime, createDate
    }

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      id = try values.decode(TianyiString.self, forKey: .id)
      name = try values.decode(String.self, forKey: .name)
      lastOpTime = try values.decodeIfPresent(String.self, forKey: .lastOpTime)
      createDate = try values.decodeIfPresent(String.self, forKey: .createDate)
    }

    var node: TianyiNode {
      TianyiNode(
        id: id.value, name: TianyiName.normalize(name), isDirectory: true, size: 0,
        modified: TianyiDate.parse(lastOpTime) ?? TianyiDate.parse(createDate) ?? .distantPast)
    }
  }
}

struct TianyiCapacity: Decodable, Sendable {
  let account: String?
  let cloudCapacityInfo: Capacity?
  let familyCapacityInfo: Capacity?

  struct Capacity: Decodable, Sendable {
    let totalSize: Int64
    let usedSize: Int64
  }
}

struct TianyiFamilyList: Decodable, Sendable {
  let familyInfoResp: [Family]?

  struct Family: Decodable, Sendable {
    let familyID: TianyiString
    let remarkName: String?

    enum CodingKeys: String, CodingKey {
      case familyID = "familyId"
      case remarkName
    }
  }
}

struct TianyiCreatedNode: Decodable, Sendable {
  let id: TianyiString?
  let name: String?
  let size: Int64?
  let lastOpTime: String?
  let createDate: String?

  enum CodingKeys: String, CodingKey {
    case id, name, size, lastOpTime, createDate
  }

  var node: TianyiNode? {
    guard let id else { return nil }
    return TianyiNode(
      id: id.value, name: TianyiName.normalize(name ?? ""), isDirectory: false,
      size: max(0, size ?? 0),
      modified: TianyiDate.parse(lastOpTime) ?? TianyiDate.parse(createDate) ?? .distantPast)
  }
}

struct TianyiTaskCreated: Decodable, Sendable {
  let taskID: String?

  enum CodingKeys: String, CodingKey {
    case taskID = "taskId"
  }
}

struct TianyiTaskStatus: Decodable, Sendable {
  let taskID: String?
  let taskStatus: Int?
  let failedCount: Int?
  let successedCount: Int?

  enum CodingKeys: String, CodingKey {
    case taskID = "taskId"
    case taskStatus, failedCount, successedCount
  }
}

struct TianyiString: Decodable, Sendable {
  let value: String

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(String.self) {
      self.value = value
    } else if let value = try? container.decode(Int64.self) {
      self.value = String(value)
    } else {
      throw DecodingError.typeMismatch(
        String.self, .init(codingPath: decoder.codingPath, debugDescription: "需要字符串或整数"))
    }
  }
}

enum TianyiName {
  static func normalize(_ value: String) -> String {
    value.replacingOccurrences(of: "\\'", with: "'")
  }
}

enum TianyiDate {
  static func parse(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    let normalized =
      value.replacingOccurrences(of: "\u{202f}", with: " ")
      .replacingOccurrences(of: "\u{00a0}", with: " ")
    let iso = ISO8601DateFormatter()
    if let date = iso.date(from: normalized) { return date }
    let formats = [
      "yyyy-MM-dd HH:mm:ss",
      "yyyy-MM-dd",
      "MMM d, yyyy h:mm:ss a Z",
      "MMM d, yyyy, h:mm:ss a Z",
      "MMM d, yyyy h:mm:ss a",
      "MMM d, yyyy, h:mm:ss a",
    ]
    for format in formats {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)
      formatter.dateFormat = format
      if let date = formatter.date(from: normalized) { return date }
    }
    return nil
  }
}

enum TianyiJSON {
  static func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T {
    do {
      return try JSONDecoder().decode(type, from: response.body)
    } catch {
      throw TianyiError.invalidResponse
    }
  }

  static func object(from data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }
}
