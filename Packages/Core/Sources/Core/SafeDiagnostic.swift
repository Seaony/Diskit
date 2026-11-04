import Foundation

public struct SafeDiagnostic: Equatable, Sendable {
  public enum Failure: String, Sendable { case http, posix, url, cocoa, application }
  public let category: DiagnosticCategory
  public let operation: DiagnosticOperation
  public let failure: Failure
  public let code: Int

  init(category: DiagnosticCategory, operation: DiagnosticOperation, status: Int) {
    self.category = category
    self.operation = operation
    failure = .http
    code = status
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
  }

  var message: String { "\(operation.rawValue) \(failure.rawValue) \(code)" }
}
