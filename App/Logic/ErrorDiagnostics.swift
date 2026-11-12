import Foundation

enum ErrorDiagnostics {
  static func summary(_ error: Error) -> String {
    chain(error).map { value in
      var detail = "domain=\(value.domain) code=\(value.code)"
      if let pid = value.userInfo[NSFileManagerUnmountDissentingProcessIdentifierErrorKey] as? NSNumber {
        detail += " dissenting_pid=\(pid.int64Value)"
      }
      return detail
    }.joined(separator: "; ")
  }

  static func chain(_ error: Error) -> [NSError] {
    var visited = Set<ObjectIdentifier>()
    var values: [NSError] = []

    func append(_ value: NSError) {
      guard visited.insert(ObjectIdentifier(value)).inserted else { return }
      values.append(value)
      for underlying in value.underlyingErrors { append(underlying as NSError) }
    }

    append(error as NSError)
    return values
  }
}
