import Foundation

enum LanzouScript {
  private enum Token: Equatable {
    case word(String), string(String), punctuation(Character)
    var value: String? {
      switch self {
      case .word(let value), .string(let value): value
      default: nil
      }
    }
  }

  struct Request {
    let endpoint: String?
    let fields: [String: String]
  }

  static func containsIdentifier(_ name: String, in html: String) -> Bool {
    tokens(in: html).contains(.word(name))
  }

  static func variables(in html: String) -> [String: String] {
    variables(tokens(in: html))
  }

  static func request(in html: String, endpointContains: [String]) throws -> Request {
    let tokens = tokens(in: html)
    let variables = variables(tokens)
    var options: [[Token]] = []
    for index in tokens.indices where tokens[index] == .word("ajax") {
      guard index + 2 < tokens.count, tokens[index + 1] == .punctuation("("),
        tokens[index + 2] == .punctuation("{"),
        let end = closingBrace(tokens, from: index + 2)
      else { continue }
      options.append(Array(tokens[(index + 3)..<end]))
    }
    // 兼容页面中独立定义的 url/data；存在 ajax 调用时只取真实调用选项。
    if options.isEmpty { options = [tokens] }
    var requests: [Request] = []
    for option in options {
      let endpoints = propertyValues("url", tokens: option, variables: variables)
      let endpointsMatching = endpoints.filter { value in
        endpointContains.contains { value.contains($0) }
      }
      if !endpoints.isEmpty, endpointsMatching.isEmpty { continue }
      let fields = dataObjects(option, variables: variables)
      guard fields.count == 1, endpointsMatching.count <= 1 else {
        throw LanzouError.invalidResponse
      }
      if let fields = fields.first {
        requests.append(Request(endpoint: endpointsMatching.first, fields: fields))
      }
    }
    guard requests.count == 1 else { throw LanzouError.invalidResponse }
    return requests[0]
  }

  static func hasEndpoint(in html: String, containing values: [String]) -> Bool {
    let tokens = tokens(in: html)
    return propertyValues("url", tokens: tokens, variables: variables(tokens)).contains {
      endpoint in
      values.contains { endpoint.contains($0) }
    }
  }

  static func fields(in html: String) -> [String: String] {
    let tokens = tokens(in: html)
    let values = dataObjects(tokens, variables: variables(tokens))
    return values.count == 1 ? values[0] : [:]
  }

  private static func variables(_ tokens: [Token]) -> [String: String] {
    var result: [String: String] = [:]
    var ambiguous = Set<String>()
    guard tokens.count > 2 else { return result }
    for index in 0..<(tokens.count - 2) {
      guard case .word(let name) = tokens[index], tokens[index + 1] == .punctuation("="),
        let value = literal(tokens[index + 2], variables: [:])
      else { continue }
      if let previous = result[name], previous != value { ambiguous.insert(name) }
      result[name] = value
    }
    for key in ambiguous { result.removeValue(forKey: key) }
    return result
  }

  private static func literal(_ token: Token, variables: [String: String]) -> String? {
    switch token {
    case .string(let value): return value
    case .word(let value): return variables[value] ?? (Int64(value) != nil ? value : nil)
    default: return nil
    }
  }

  private static func propertyValues(_ name: String, tokens: [Token], variables: [String: String])
    -> [String]
  {
    guard tokens.count > 2 else { return [] }
    return (0..<(tokens.count - 2)).compactMap { index in
      guard tokens[index].value == name, tokens[index + 1] == .punctuation(":") else { return nil }
      return literal(tokens[index + 2], variables: variables)
    }
  }

  private static func dataObjects(_ tokens: [Token], variables: [String: String]) -> [[String:
    String]]
  {
    guard tokens.count > 2 else { return [] }
    var result: [[String: String]] = []
    for index in 0..<(tokens.count - 2)
    where tokens[index].value == "data" && tokens[index + 1] == .punctuation(":") {
      if case .string(let text) = tokens[index + 2] {
        let decoded = text.removingPercentEncoding ?? text
        if let object = try? JSONSerialization.jsonObject(with: Data(decoded.utf8))
          as? [String: Any]
        {
          guard object.values.allSatisfy({ LanzouValues.string($0) != nil }) else { continue }
          result.append(object.compactMapValues(LanzouValues.string))
        } else if decoded.contains("=") {
          var fields: [String: String] = [:]
          let form = text.contains("=") ? text : decoded
          for item in form.split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 {
              let key = String(pair[0]).replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding
              let value = String(pair[1]).replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding
              if let key, let value { fields[key] = value }
            }
          }
          result.append(fields)
        }
      } else if tokens[index + 2] == .punctuation("{"),
        let end = closingBrace(tokens, from: index + 2)
      {
        var cursor = index + 3
        var fields: [String: String] = [:]
        while cursor + 2 < end {
          guard let key = tokens[cursor].value, tokens[cursor + 1] == .punctuation(":"),
            let value = literal(tokens[cursor + 2], variables: variables)
              ?? (["pg", "p", "pwd"].contains(key) ? "" : nil)
          else { break }
          fields[key] = value
          cursor += 3
          if cursor < end, tokens[cursor] == .punctuation(",") { cursor += 1 }
        }
        if cursor == end { result.append(fields) }
      }
    }
    return result
  }

  private static func closingBrace(_ tokens: [Token], from start: Int) -> Int? {
    var depth = 0
    for index in start..<tokens.count {
      if tokens[index] == .punctuation("{") { depth += 1 }
      if tokens[index] == .punctuation("}") {
        depth -= 1
        if depth == 0 { return index }
      }
    }
    return nil
  }

  private static func tokens(in html: String) -> [Token] {
    let clean = html.replacingOccurrences(
      of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
    let scripts = LanzouHTML.allMatches(#"<script\b[^>]*>(.*?)</script>"#, in: clean)
    return scripts.flatMap { match -> [Token] in
      guard let script = match[safe: 1] ?? nil else { return [] }
      let characters = Array(script)
      var output: [Token] = []
      var index = 0
      while index < characters.count {
        let character = characters[index]
        if character.isWhitespace {
          index += 1
          continue
        }
        if character == "/", index + 1 < characters.count {
          if characters[index + 1] == "/" {
            index += 2
            while index < characters.count, characters[index] != "\n" { index += 1 }
            continue
          }
          if characters[index + 1] == "*" {
            index += 2
            while index + 1 < characters.count,
              !(characters[index] == "*" && characters[index + 1] == "/")
            { index += 1 }
            index = min(index + 2, characters.count)
            continue
          }
        }
        if character == "'" || character == "\"" || character == "`" {
          let quote = character
          index += 1
          var value = ""
          while index < characters.count, characters[index] != quote {
            if characters[index] == "\\", index + 1 < characters.count {
              index += 1
              switch characters[index] {
              case "n": value.append("\n")
              case "r": value.append("\r")
              case "t": value.append("\t")
              case "x", "u":
                let length = characters[index] == "x" ? 2 : 4
                guard index + length < characters.count,
                  let number = UInt32(
                    String(characters[(index + 1)...(index + length)]), radix: 16),
                  let scalar = UnicodeScalar(number)
                else { return [] }
                value.unicodeScalars.append(scalar)
                index += length
              default: value.append(characters[index])
              }
            } else {
              value.append(characters[index])
            }
            index += 1
          }
          guard index < characters.count else { return [] }
          output.append(.string(value))
          index += 1
        } else if character.isLetter || character.isNumber || character == "_" || character == "$" {
          let start = index
          while index < characters.count,
            characters[index].isLetter || characters[index].isNumber || characters[index] == "_"
              || characters[index] == "$"
          { index += 1 }
          output.append(.word(String(characters[start..<index])))
        } else {
          output.append(.punctuation(character))
          index += 1
        }
      }
      return output
    }
  }
}
