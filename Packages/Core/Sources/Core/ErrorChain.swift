import Foundation

// 把错误逐层展开成文字（类型、错误域、错误码、说明），日志和「复制详细信息」共用，原样保留不删改
public enum ErrorChain {
  public static func lines(_ error: Error) -> [String] {
    var lines: [String] = []
    var visited = Set<ObjectIdentifier>()
    func describe(_ error: Error, depth: Int) {
      guard depth < 8 else { return }
      // 扩展里挂载失败的完整报告原样放进来，再接 App 这边拿到的错误
      if let mount = error as? ExtensionMountFailure {
        lines.append("Extension report:")
        lines += mount.record.report.split(separator: "\n", omittingEmptySubsequences: false)
          .map { "  " + $0 }
        describe(mount.underlying, depth: depth + 1)
        return
      }
      if let remote = error as? RemoteError {
        switch remote {
        case .failed(let code, let reason): lines.append("RemoteError.failed errno \(code): \(reason)")
        case .posix(let code): lines.append("RemoteError.posix errno \(code)")
        case .http(let status): lines.append("RemoteError.http \(status)")
        case .malformed(let reason): lines.append("RemoteError.malformed: \(reason)")
        default: lines.append("RemoteError.\(remote)")
        }
        return
      }
      let value = error as NSError
      guard visited.insert(ObjectIdentifier(value)).inserted else { return }
      var line = "\(String(reflecting: type(of: error))) \(value.domain) \(HumanError.code(value)): \(value.localizedDescription)"
      if let reason = value.localizedFailureReason, !reason.isEmpty { line += " | " + reason }
      if let debug = value.userInfo[NSDebugDescriptionErrorKey] as? String, !debug.isEmpty {
        line += " | " + debug
      }
      lines.append(line)
      for underlying in value.underlyingErrors { describe(underlying, depth: depth + 1) }
    }
    describe(error, depth: 0)
    return lines
  }
}
