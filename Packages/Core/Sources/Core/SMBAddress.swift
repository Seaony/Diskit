import Foundation

public enum SMBAddress {
  public static func url(host: String, user: String? = nil, share: String? = nil) throws -> URL {
    guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || "/@?#".contains($0) }) else {
      throw ConnectionError.invalidFields
    }
    var parts = URLComponents()
    parts.scheme = "smb"
    parts.host = host
    parts.user = user
    if let share { parts.path = "/" + share }
    guard let url = parts.url else { throw ConnectionError.invalidFields }
    return url
  }
  public static func parseShares(_ output: String, exitStatus: Int32) throws -> [String] {
    guard exitStatus == 0 else {
      let lower = output.lowercased()
      if lower.contains("authentication") || lower.contains("logon failure")
        || lower.contains("permission denied") || lower.contains("password incorrect")
      {
        throw ConnectionError.authentication
      }
      if lower.contains("timed out") { throw ConnectionError.timeout }
      throw ConnectionError.system(exitStatus)
    }
    // smbutil 的共享名可以含空格，从类型列向前取完整名称。
    let regex = try NSRegularExpression(
      pattern: #"^(.+?)\s{2,}(Disk|Printer|Pipe|Comm|Unknown)\s*(.*)$"#)
    return output.components(separatedBy: .newlines).compactMap { line in
      let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
        let nameRange = Range(match.range(at: 1), in: text),
        let typeRange = Range(match.range(at: 2), in: text), text[typeRange] == "Disk"
      else { return nil }
      return String(text[nameRange]).trimmingCharacters(in: .whitespaces)
    }
  }
}
