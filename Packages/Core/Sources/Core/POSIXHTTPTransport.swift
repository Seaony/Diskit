import Foundation
import Network

public enum NetworkFailure {
  private static let sourceKey = "com.seaony.Diskit.networkFailure"

  public static func isTransportError(_ error: Error) -> Bool {
    let source = error as NSError
    return error is NWError || source.domain == NSURLErrorDomain
      || source.userInfo[sourceKey] as? Bool == true
  }

  public static func posix(_ error: Error) -> Error {
    if error is CancellationError { return error }
    let source = error as NSError
    if source.domain == NSPOSIXErrorDomain { return error }
    let code: Int32
    if let network = error as? NWError {
      switch network {
      case .posix(let value): code = value.rawValue
      case .dns: code = EHOSTUNREACH
      case .tls: code = EACCES
      case .wifiAware: code = EIO
      @unknown default: code = EIO
      }
    } else if source.domain == NSURLErrorDomain {
      switch URLError.Code(rawValue: source.code) {
      case .cancelled: return CancellationError()
      case .timedOut: code = ETIMEDOUT
      case .notConnectedToInternet: code = ENETUNREACH
      case .networkConnectionLost: code = ECONNRESET
      case .cannotConnectToHost: code = ECONNREFUSED
      case .cannotFindHost, .dnsLookupFailed: code = EHOSTUNREACH
      case .badURL, .unsupportedURL: code = EINVAL
      case .userAuthenticationRequired, .userCancelledAuthentication,
        .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
        .clientCertificateRejected, .clientCertificateRequired, .dataNotAllowed:
        code = EACCES
      default: code = EIO
      }
    } else {
      code = EIO
    }
    return NSError(
      domain: NSPOSIXErrorDomain, code: Int(code),
      userInfo: [
        NSLocalizedDescriptionKey: HumanError.posix(code), NSUnderlyingErrorKey: error,
        sourceKey: true,
      ])
  }
}

public struct POSIXHTTPTransport: HTTPTransport {
  private let base: any HTTPTransport
  public init(_ base: any HTTPTransport) { self.base = base }

  public func send(_ request: URLRequest) async throws -> HTTPResponse {
    do { return try await base.send(request) } catch { throw NetworkFailure.posix(error) }
  }

  public func upload(_ request: URLRequest) async throws -> HTTPResponse {
    do { return try await base.upload(request) } catch { throw NetworkFailure.posix(error) }
  }

  public func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    do {
      let response = try await base.stream(request)
      let cursor = POSIXHTTPCursor(response.body)
      return HTTPStreamResponse(
        response: response.response,
        body: AsyncThrowingStream(unfolding: { try await cursor.next() }))
    } catch { throw NetworkFailure.posix(error) }
  }
}

private actor POSIXHTTPCursor {
  private var iterator: AsyncThrowingStream<Data, Error>.Iterator?
  private var finished = false
  init(_ body: AsyncThrowingStream<Data, Error>) { iterator = body.makeAsyncIterator() }

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
      throw NetworkFailure.posix(error)
    }
  }
}
