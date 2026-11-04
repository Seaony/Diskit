import Foundation
import Network
import Testing

@testable import Core

@Test func remoteErrorsBridgeToPOSIXWithoutLosingDescriptions() {
  let cases: [(RemoteError, Int32)] = [
    (.invalidPath, EINVAL), (.notConnected, EIO), (.protocolError, EIO),
    (.unauthorized, EACCES), (.occupied, EBUSY), (.tooLarge, EFBIG),
    (.unsupported, ENOTSUP), (.rateLimited, EAGAIN), (.posix(ENOTEMPTY), ENOTEMPTY),
    (.http(400), EINVAL), (.http(401), EACCES), (.http(403), EACCES),
    (.http(404), ENOENT), (.http(408), ETIMEDOUT), (.http(409), EEXIST),
    (.http(412), EEXIST), (.http(416), EINVAL), (.http(429), EAGAIN),
    (.http(500), EIO), (.http(501), ENOTSUP), (.http(503), EAGAIN),
    (.http(504), ETIMEDOUT), (.http(505), ENOTSUP), (.http(507), ENOSPC),
  ]
  for (error, code) in cases {
    let bridged = error as NSError
    #expect(bridged.domain == NSPOSIXErrorDomain)
    #expect(bridged.code == Int(code))
    #expect(bridged.localizedDescription == error.errorDescription)
  }
}

@Test func networkFailuresMapToPOSIXAndPreserveCancellation() {
  let cases: [(URLError.Code, Int32)] = [
    (.timedOut, ETIMEDOUT), (.notConnectedToInternet, ENETUNREACH),
    (.networkConnectionLost, ECONNRESET), (.cannotConnectToHost, ECONNREFUSED),
    (.cannotFindHost, EHOSTUNREACH), (.dnsLookupFailed, EHOSTUNREACH),
    (.badURL, EINVAL), (.unsupportedURL, EINVAL),
    (.serverCertificateUntrusted, EACCES), (.userAuthenticationRequired, EACCES),
    (.badServerResponse, EIO),
  ]
  for (source, expected) in cases {
    let error = NetworkFailure.posix(URLError(source)) as NSError
    #expect(error.domain == NSPOSIXErrorDomain)
    #expect(error.code == Int(expected))
    #expect((error.userInfo[NSUnderlyingErrorKey] as? URLError)?.code == source)
    #expect(NetworkFailure.isTransportError(error))
  }
  #expect(NetworkFailure.posix(CancellationError()) is CancellationError)
  #expect(NetworkFailure.posix(URLError(.cancelled)) is CancellationError)
  let original = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
  #expect(NetworkFailure.posix(original) as NSError === original)
  #expect(!NetworkFailure.isTransportError(RemoteError.unauthorized))
  #expect(!NetworkFailure.isTransportError(POSIXError(.EACCES)))
  #expect(NetworkFailure.isTransportError(URLError(.serverCertificateUntrusted)))
  #expect((NetworkFailure.posix(NWError.posix(.ETIMEDOUT)) as NSError).code == Int(ETIMEDOUT))
  #expect(
    (NetworkFailure.posix(NWError.posix(.ECONNREFUSED)) as NSError).domain == NSPOSIXErrorDomain)
  #expect((NetworkFailure.posix(NWError.dns(-65537)) as NSError).code == Int(EHOSTUNREACH))
  #expect((NetworkFailure.posix(NWError.tls(-9807)) as NSError).code == Int(EACCES))
  #expect((NetworkFailure.posix(NWError.wifiAware(1)) as NSError).code == Int(EIO))
}

private struct FailingPOSIXTransport: HTTPTransport {
  let failure: URLError.Code
  func send(_ request: URLRequest) async throws -> HTTPResponse { throw URLError(failure) }
  func upload(_ request: URLRequest) async throws -> HTTPResponse { throw URLError(failure) }
  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    HTTPStreamResponse(
      response: HTTPResponse(status: 200),
      body: AsyncThrowingStream {
        $0.yield(Data([1, 2]))
        $0.finish(throwing: URLError(failure))
      })
  }
}

@Test(arguments: ["send", "upload", "body"])
func posixHTTPTransportMapsEveryRequestPhase(phase: String) async throws {
  let transport = POSIXHTTPTransport(FailingPOSIXTransport(failure: .timedOut))
  let request = URLRequest(url: URL(string: "https://example.invalid/file")!)
  var output = Data()
  do {
    if phase == "send" {
      _ = try await transport.send(request)
    } else if phase == "upload" {
      _ = try await transport.upload(request)
    } else {
      for try await chunk in try await transport.stream(request).body { output.append(chunk) }
    }
    Issue.record("网络失败必须抛出")
  } catch {
    #expect((error as NSError).domain == NSPOSIXErrorDomain)
    #expect((error as NSError).code == Int(ETIMEDOUT))
  }
  if phase == "body" { #expect(output == Data([1, 2])) }
}
