import Core
import Foundation

enum ErrorDiagnostics {
  // 日志里记完整错误链（每层的错误域、错误码、原文），推出被占用时再补上占用者的进程号
  static func summary(_ error: Error) -> String {
    let pids = chain(error).compactMap {
      ($0.userInfo[NSFileManagerUnmountDissentingProcessIdentifierErrorKey] as? NSNumber)?.int64Value
    }
    let text = ErrorChain.lines(error).joined(separator: " <- ")
    return pids.isEmpty ? text : text + " dissenting_pid=" + pids.map(String.init).joined(separator: ",")
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
