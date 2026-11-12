import Foundation

struct CLIEnvironment {
  let values: [String: String]
  func value(_ name: String, fallback: String = "") -> String { values[name] ?? fallback }

  static func load(
    _ environment: [String: String],
    read: (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) }
  ) throws -> CLIEnvironment {
    var values: [String: String] = [:]
    if let path = environment["DISKIT_SECRETS_FILE"], !path.isEmpty {
      values = parse(try read(URL(fileURLWithPath: path)))
    }
    values.merge(environment) { _, override in override }
    return CLIEnvironment(values: values)
  }

  static func parse(_ contents: String) -> [String: String] {
    var values: [String: String] = [:]
    for raw in contents.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard !line.hasPrefix("#"), !line.hasPrefix("//"), let equals = line.firstIndex(of: "=")
      else { continue }
      let key = line[..<equals].trimmingCharacters(in: .whitespaces)
      var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("\""), let end = value.dropFirst().firstIndex(of: "\"") {
        value = String(value[value.index(after: value.startIndex)..<end])
      } else if let comment = value.range(of: " //") {
        value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
      }
      guard !key.isEmpty else { continue }
      values[key] = value.replacingOccurrences(of: "$()", with: "")
    }
    return values
  }
}
