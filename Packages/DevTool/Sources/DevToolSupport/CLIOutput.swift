import Core
import Foundation

public enum CLIOutput {
  static func listLine(_ item: RemoteItem) -> String {
    let line = "\(item.isDirectory ? "d" : "-")\t\(item.size)\t\(item.name)"
    guard item.path.value.split(separator: "/").last.map(String.init) != item.name else {
      return line
    }
    let quoted = "'" + item.path.value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    return line + "\t" + quoted
  }

  public static func errorMessage(_ error: Error) -> String {
    if error is CancellationError { return "操作已取消" }
    if let error = error as? RemoteError { return HumanError.detail(error) }
    let value = error as NSError
    if value.domain == NSPOSIXErrorDomain {
      return HumanError.posix(Int32(clamping: value.code)) + " (errno \(value.code))"
    }
    if value.domain == NSURLErrorDomain {
      return HumanError.posix(value.code == NSURLErrorTimedOut ? ETIMEDOUT : EIO)
    }
    return "操作失败（\(value.domain)，\(value.code)）"
  }
}
