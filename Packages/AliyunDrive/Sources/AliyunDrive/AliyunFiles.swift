import Core
import Foundation

struct AliyunFile: Decodable, Sendable {
  let fileID: String
  let name: String
  let type: String
  let size: Int64?
  let updatedAt: String?
  enum CodingKeys: String, CodingKey {
    case fileID = "file_id"
    case name, type, size
    case updatedAt = "updated_at"
  }
  var isDirectory: Bool { type == "folder" }
  func item(at path: RemotePath) throws -> RemoteItem {
    guard !fileID.isEmpty, type == "file" || type == "folder", !name.isEmpty,
      !name.contains("/"), name != ".", name != ".."
    else { throw RemoteError.protocolError }
    guard isDirectory || (size != nil && size! >= 0) else { throw RemoteError.protocolError }
    let modified: Date
    if let updatedAt, let date = RemoteTimestamp.parse(updatedAt) {
      modified = date
    } else {
      throw RemoteError.protocolError
    }
    return RemoteItem(
      path: path, name: name, isDirectory: isDirectory, size: size ?? 0, modified: modified)
  }
}

struct AliyunFileList: Decodable, Sendable {
  let items: [AliyunFile]
  let nextMarker: String?
  enum CodingKeys: String, CodingKey {
    case items
    case nextMarker = "next_marker"
  }
}

struct AliyunDownloadLink: Decodable, Sendable {
  let url: URL
  let expiration: String
  let method: String
  var expiresAt: Date? { RemoteTimestamp.parse(expiration) }
}

struct AliyunPartURL: Decodable, Sendable {
  let partNumber: Int
  let uploadURL: URL
  enum CodingKeys: String, CodingKey {
    case partNumber = "part_number"
    case uploadURL = "upload_url"
  }
}

struct AliyunCreatedFile: Decodable, Sendable {
  let fileID: String
  let uploadID: String?
  let rapidUpload: Bool?
  let partInfoList: [AliyunPartURL]?
  enum CodingKeys: String, CodingKey {
    case fileID = "file_id"
    case uploadID = "upload_id"
    case rapidUpload = "rapid_upload"
    case partInfoList = "part_info_list"
  }
}

struct AliyunUploadURLs: Decodable, Sendable {
  let partInfoList: [AliyunPartURL]
  enum CodingKeys: String, CodingKey { case partInfoList = "part_info_list" }
}

struct AliyunMutation: Decodable, Sendable {
  let asyncTaskID: String?
  enum CodingKeys: String, CodingKey { case asyncTaskID = "async_task_id" }
}

struct AliyunTaskState: Decodable, Sendable { let state: String }

struct AliyunPart: Equatable, Sendable {
  let number: Int
  let offset: Int64
  let length: Int64
}

enum AliyunMultipart {
  static let defaultPartSize: Int64 = 10 * 1024 * 1024
  static func parts(size: Int64, partSize: Int64 = defaultPartSize) throws -> [AliyunPart] {
    guard size >= 0, partSize > 0 else { throw RemoteError.posix(EINVAL) }
    if size == 0 { return [AliyunPart(number: 1, offset: 0, length: 0)] }
    let minimumForCount = size / 10_000 + (size % 10_000 == 0 ? 0 : 1)
    let actualSize = max(partSize, minimumForCount)
    guard actualSize <= 5 * 1024 * 1024 * 1024 else { throw RemoteError.posix(EFBIG) }
    var result: [AliyunPart] = []
    var offset: Int64 = 0
    while offset < size {
      let length = min(actualSize, size - offset)
      result.append(AliyunPart(number: result.count + 1, offset: offset, length: length))
      offset += length
    }
    return result
  }
}

public enum AliyunFileError: Error, LocalizedError, CustomNSError, Sendable {
  case duplicateNames, replacementCleanupFailed
  public static var errorDomain: String { NSPOSIXErrorDomain }
  public var errorCode: Int { self == .duplicateNames ? Int(EEXIST) : Int(EIO) }
  public var errorDescription: String? {
    switch self {
    case .duplicateNames: L("目录中已有多份同名文件，无法确定要操作哪一份")
    case .replacementCleanupFailed: L("新文件已上传，旧文件回收失败或结果未确认，请检查同名文件")
    }
  }
  public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
}
