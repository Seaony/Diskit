import Foundation

public struct DiagnosticHTTPTransport: HTTPTransport {
  private let base: any HTTPTransport
  private let category: DiagnosticCategory
  private let record: @Sendable (SafeDiagnostic) -> Void

  public init(_ base: any HTTPTransport, category: DiagnosticCategory) {
    self.base = base
    self.category = category
    record = PackageDiagnostics.emit
  }

  init(
    _ base: any HTTPTransport, category: DiagnosticCategory,
    record: @escaping @Sendable (SafeDiagnostic) -> Void
  ) {
    self.base = base
    self.category = category
    self.record = record
  }

  public func send(_ request: URLRequest) async throws -> HTTPResponse {
    do {
      let response = try await base.send(request)
      recordStatus(response.status, operation: .request)
      return response
    } catch {
      recordFailure(error, operation: .request)
      throw error
    }
  }

  public func upload(_ request: URLRequest) async throws -> HTTPResponse {
    do {
      let response = try await base.upload(request)
      recordStatus(response.status, operation: .upload)
      return response
    } catch {
      recordFailure(error, operation: .upload)
      throw error
    }
  }

  public func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    do {
      let response = try await base.stream(request)
      recordStatus(response.response.status, operation: .download)
      let cursor = DiagnosticHTTPCursor(response.body, category: category, record: record)
      return HTTPStreamResponse(
        response: response.response,
        body: AsyncThrowingStream(unfolding: { try await cursor.next() }))
    } catch {
      recordFailure(error, operation: .download)
      throw error
    }
  }

  private func recordStatus(_ status: Int, operation: DiagnosticOperation) {
    if status >= 400 {
      record(SafeDiagnostic(category: category, operation: operation, status: status))
    }
  }

  private func recordFailure(_ error: Error, operation: DiagnosticOperation) {
    if let event = SafeDiagnostic(category: category, operation: operation, error: error) {
      record(event)
    }
  }
}

private actor DiagnosticHTTPCursor {
  private var iterator: AsyncThrowingStream<Data, Error>.Iterator?
  private let category: DiagnosticCategory
  private let record: @Sendable (SafeDiagnostic) -> Void
  private var finished = false

  init(
    _ body: AsyncThrowingStream<Data, Error>, category: DiagnosticCategory,
    record: @escaping @Sendable (SafeDiagnostic) -> Void
  ) {
    iterator = body.makeAsyncIterator()
    self.category = category
    self.record = record
  }

  func next() async throws -> Data? {
    if finished { return nil }
    guard var current = iterator else { throw RemoteError.protocolError }
    iterator = nil
    do {
      try Task.checkCancellation()
      let data = try await current.next(isolation: self)
      if data == nil { finished = true } else { iterator = current }
      return data
    } catch {
      finished = true
      if let event = SafeDiagnostic(category: category, operation: .download, error: error) {
        record(event)
      }
      throw error
    }
  }
}
