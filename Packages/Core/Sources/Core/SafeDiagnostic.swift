import Foundation

public struct SafeDiagnostic: Equatable, Sendable {
  public enum Failure: String, Sendable { case http, posix, url, cocoa, application }
  public let category: DiagnosticCategory
  public let operation: DiagnosticOperation
  public let failure: Failure
  public let code: Int
  // 每一层错误的完整原因（错误域、错误码、说明）
  public let chain: String

  init(category: DiagnosticCategory, operation: DiagnosticOperation, status: Int) {
    self.category = category
    self.operation = operation
    failure = .http
    code = status
    chain = ""
  }

  init?(category: DiagnosticCategory, operation: DiagnosticOperation, error: Error) {
    if error is CancellationError { return nil }
    let value = error as NSError
    if value.domain == NSURLErrorDomain, value.code == NSURLErrorCancelled { return nil }
    if value.domain == NSPOSIXErrorDomain, value.code == Int(ECANCELED) { return nil }
    self.category = category
    self.operation = operation
    switch value.domain {
    case NSPOSIXErrorDomain:
      failure = .posix
      code = value.code
    case NSURLErrorDomain:
      failure = .url
      code = value.code
    case NSCocoaErrorDomain:
      failure = .cocoa
      code = value.code
    default:
      failure = .application
      code = value.code
    }
    chain = Self.chain(error)
  }

  var message: String { "\(operation.rawValue) \(failure.rawValue) \(code)" }
  var logLine: String { chain.isEmpty ? message : message + " | " + chain }

  static func chain(_ error: Error) -> String {
    ErrorChain.lines(error).joined(separator: " <- ")
  }
}
