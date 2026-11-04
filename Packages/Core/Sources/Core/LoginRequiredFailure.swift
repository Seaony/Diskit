public protocol LoginRequiredFailure: Error {
  var requiresLogin: Bool { get }
}
