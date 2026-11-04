import Core
import Foundation

enum LanzouJSON {
  static func object(_ data: Data) throws -> [String: Any] {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw LanzouError.invalidResponse
    }
    return object
  }

  static func successfulObject(_ data: Data) throws -> [String: Any] {
    do {
      let object = try object(data)
      guard let status = integer(object["zt"]) else { throw LanzouError.invalidResponse }
      switch status {
      case 1, 2: return object
      case 4:
        let errorMessage = message(in: object)
        throw errorMessage.isEmpty ? LanzouError.rateLimited : businessError(errorMessage)
      case 9: throw LanzouError.authenticationExpired
      default: throw businessError(message(in: object))
      }
    } catch {
      PackageDiagnostics.failure(error, category: .lanzouDrive, operation: .request)
      throw error
    }
  }

  static func array(_ value: Any?) -> [[String: Any]] {
    value as? [[String: Any]] ?? []
  }

  static func integer(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let text = value as? String { return Int(text) }
    return nil
  }

  static func message(in object: [String: Any]) -> String {
    ["inf", "info", "msg"].compactMap { LanzouValues.string(object[$0]) }.first {
      !$0.isEmpty
    } ?? ""
  }

  static func businessError(_ rawMessage: String) -> LanzouError {
    let message = LanzouHTML.strippedText(rawMessage)
    let lower = message.lowercased()
    if message.contains("密码") { return .invalidPassword }
    if message.contains("频繁") || message.contains("稍后") || lower.contains("rate")
      || lower.contains("too many")
    {
      return .rateLimited
    }
    if message.contains("不存在") || message.contains("取消分享") {
      return .notFound
    }
    if message.contains("登录") || message.contains("未授权") {
      return .authenticationExpired
    }
    return .service(message)
  }
}

struct LanzouEntry: Sendable {
  let name: String
  let isDirectory: Bool
  let size: Int64?
  let modified: Date
  let id: String

  static func accountFolder(_ value: [String: Any]) throws -> LanzouEntry {
    let id = LanzouValues.string(value["fol_id"]) ?? ""
    return try account(value, id: id, isDirectory: true)
  }

  static func accountFile(_ value: [String: Any]) throws -> LanzouEntry {
    let id = LanzouValues.string(value["id"]) ?? ""
    return try account(value, id: id, isDirectory: false)
  }

  static func shareFile(_ value: [String: Any]) throws -> LanzouEntry {
    let id = LanzouValues.string(value["id"]) ?? ""
    let name =
      LanzouValues.string(value["name_all"]) ?? LanzouValues.string(value["name"]) ?? ""
    guard !id.isEmpty else { throw LanzouError.invalidResponse }
    return LanzouEntry(
      name: name, isDirectory: false, size: LanzouValues.parseSize(value["size"]),
      modified: LanzouValues.parseDate(LanzouValues.string(value["time"])), id: id)
  }

  private static func account(
    _ value: [String: Any], id: String, isDirectory: Bool
  ) throws -> LanzouEntry {
    let name =
      isDirectory
      ? LanzouValues.string(value["name"])
      : LanzouValues.string(value["name_all"]) ?? LanzouValues.string(value["name"])
    guard !id.isEmpty, let name, !name.isEmpty, !name.contains("/"), name != ".", name != ".."
    else { throw LanzouError.invalidResponse }
    return LanzouEntry(
      name: name, isDirectory: isDirectory,
      size: isDirectory ? 0 : LanzouValues.parseSize(value["size"]),
      modified: LanzouValues.parseDate(LanzouValues.string(value["time"])), id: id)
  }
}
