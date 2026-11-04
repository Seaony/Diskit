import Foundation

actor LanzouDownloadBody {
  private var iterator: AsyncThrowingStream<Data, Error>.Iterator?
  private let expectedLength: Int64?
  private var received: Int64 = 0

  private var inspectHTML: Bool
  private var prefix = Data()

  init(_ stream: AsyncThrowingStream<Data, Error>, expectedLength: Int64?, inspectHTML: Bool) {
    iterator = stream.makeAsyncIterator()
    self.expectedLength = expectedLength
    self.inspectHTML = inspectHTML
  }

  func next() async throws -> Data? {
    try Task.checkCancellation()
    guard var current = iterator else { return nil }
    iterator = nil
    while true {
      let chunk = try await current.next(isolation: self)
      try Task.checkCancellation()
      if let chunk {
        if let expectedLength, Int64(chunk.count) > expectedLength - received {
          throw LanzouError.invalidResponse
        }
        received += Int64(chunk.count)
      } else if let expectedLength, received != expectedLength {
        throw LanzouError.invalidResponse
      }
      if inspectHTML {
        if let chunk { prefix.append(chunk) }
        if chunk != nil, prefix.count < 512 { continue }
        guard !Self.looksLikeHTML(prefix.prefix(512)) else { throw LanzouError.antiBotChallenge }
        inspectHTML = false
        if chunk != nil { iterator = current }
        let buffered = prefix
        prefix = Data()
        return buffered.isEmpty ? nil : buffered
      }
      if chunk != nil { iterator = current }
      return chunk
    }
  }

  private static func looksLikeHTML(_ data: Data) -> Bool {
    let text = String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
      .lowercased()
    for tag in ["<!doctype html", "<html", "<head", "<body", "<script"] where text.hasPrefix(tag) {
      let tail = text.dropFirst(tag.count)
      if tail.isEmpty || tail.first == ">" || tail.first?.isWhitespace == true { return true }
    }
    return false
  }
}
