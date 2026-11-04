import Foundation

actor LanzouDownloadBody {
  private var iterator: AsyncThrowingStream<Data, Error>.Iterator?
  private let expectedLength: Int64?
  private var received: Int64 = 0

  init(_ stream: AsyncThrowingStream<Data, Error>, expectedLength: Int64?) {
    iterator = stream.makeAsyncIterator()
    self.expectedLength = expectedLength
  }

  func next() async throws -> Data? {
    try Task.checkCancellation()
    guard var current = iterator else { return nil }
    iterator = nil
    let chunk = try await current.next(isolation: self)
    try Task.checkCancellation()
    if let chunk {
      if let expectedLength, Int64(chunk.count) > expectedLength - received {
        throw LanzouError.invalidResponse
      }
      received += Int64(chunk.count)
      iterator = current
    } else if let expectedLength, received != expectedLength {
      throw LanzouError.invalidResponse
    }
    return chunk
  }
}
