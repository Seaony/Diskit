import Foundation
import Synchronization
import Testing

@testable import Core

@Test func diagnosticsKeepTheFullErrorChain() throws {
  let underlying = NSError(
    domain: "IOUSBHostErrorDomain", code: -536_870_199,
    userInfo: [NSLocalizedDescriptionKey: "Failed to create IOUSBHostInterface."])
  let error = NSError(
    domain: "Example", code: 17,
    userInfo: [NSLocalizedDescriptionKey: "outer failure", NSUnderlyingErrorKey: underlying])
  let event = try #require(SafeDiagnostic(category: .quark, operation: .request, error: error))
  #expect(event.message == "request application 17")
  #expect(event.logLine.contains("Example 17: outer failure"))
  #expect(event.logLine.contains("IOUSBHostErrorDomain -536870199 (0xe00002c9): Failed to create IOUSBHostInterface."))
  let reason = SafeDiagnostic(
    category: .adb, operation: .connect, error: RemoteError.failed(EIO, "phone said no"))
  #expect(reason?.logLine.contains("errno 5: phone said no") == true)
  #expect(SafeDiagnostic(category: .adb, operation: .connect, error: CancellationError()) == nil)
  #expect(SafeDiagnostic(category: .adb, operation: .connect, error: URLError(.cancelled)) == nil)
  #expect(SafeDiagnostic(category: .adb, operation: .connect, error: POSIXError(.ECANCELED)) == nil)
}

private final class DiagnosticRecorder: Sendable {
  let events = Mutex<[SafeDiagnostic]>([])
  func append(_ event: SafeDiagnostic) { events.withLock { $0.append(event) } }
}

private struct DiagnosticFixture: HTTPTransport {
  let cancelled: Bool
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    HTTPResponse(
      status: 403, headers: ["Set-Cookie": "secret"], body: Data("private-content".utf8),
      url: request.url)
  }
  func upload(_ request: URLRequest) async throws -> HTTPResponse {
    if cancelled { throw CancellationError() }
    return HTTPResponse(status: 507)
  }
  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    HTTPStreamResponse(
      response: HTTPResponse(status: 200),
      body: AsyncThrowingStream { continuation in
        continuation.yield(Data([1, 2]))
        continuation.yield(Data([3]))
        if cancelled {
          continuation.finish(throwing: CancellationError())
        } else {
          continuation.finish(throwing: POSIXError(.ECONNRESET))
        }
      })
  }
}

@Test func diagnosticTransportPreservesUploadAndRedactsResponse() async throws {
  let recorder = DiagnosticRecorder()
  let transport = DiagnosticHTTPTransport(
    DiagnosticFixture(cancelled: false), category: .quark, record: recorder.append)
  var request = URLRequest(url: URL(string: "https://example.invalid/?token=secret")!)
  request.setValue("secret", forHTTPHeaderField: "Authorization")
  request.httpBody = Data("private-content".utf8)
  #expect(try await transport.send(request).status == 403)
  #expect(try await transport.upload(request).status == 507)
  let events = recorder.events.withLock { $0 }
  #expect(events.map(\.message) == ["request http 403", "upload http 507"])
  #expect(!String(describing: events).contains("secret"))
  #expect(!String(describing: events).contains("private-content"))
}

@Test func diagnosticStreamRecordsOnlyFailureAndPreservesCancellation() async throws {
  for cancelled in [false, true] {
    let recorder = DiagnosticRecorder()
    let transport = DiagnosticHTTPTransport(
      DiagnosticFixture(cancelled: cancelled), category: .s3Drive, record: recorder.append)
    let request = URLRequest(url: URL(string: "https://example.invalid")!)
    let response = try await transport.stream(request)
    var iterator = response.body.makeAsyncIterator()
    #expect(try await iterator.next() == Data([1, 2]))
    #expect(try await iterator.next() == Data([3]))
    #expect(recorder.events.withLock { $0.isEmpty })
    do {
      _ = try await iterator.next()
      Issue.record("流应保留原始失败")
    } catch {
      if cancelled {
        #expect(error is CancellationError)
      } else {
        #expect((error as? POSIXError)?.code == .ECONNRESET)
      }
    }
    #expect(try await iterator.next() == nil)
    #expect(recorder.events.withLock { $0.count } == (cancelled ? 0 : 1))
    if cancelled {
      do {
        _ = try await transport.upload(request)
        Issue.record("上传应保留取消")
      } catch { #expect(error is CancellationError) }
      #expect(recorder.events.withLock { $0.isEmpty })
    }
  }
}
