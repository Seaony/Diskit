import Foundation

struct QuitFailure: Equatable {
  struct Location: Identifiable, Equatable {
    let id: String
    let name: String
    let reason: String
  }

  let locations: [Location]
  let reason: String

  static func reason(for error: Error) -> String {
    var seen = Set<String>()
    return ErrorDiagnostics.chain(error).map(\.localizedDescription)
      .filter { seen.insert($0).inserted }.joined(separator: "\n")
  }
}
