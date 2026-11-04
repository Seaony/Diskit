import AppKit

enum OperationAlertAction {
  case retry, copy, dismiss

  static func resolve(_ response: NSApplication.ModalResponse, hasRetry: Bool) -> Self {
    if hasRetry, response == .alertFirstButtonReturn { return .retry }
    if response == (hasRetry ? .alertThirdButtonReturn : .alertSecondButtonReturn) { return .copy }
    return .dismiss
  }
}
