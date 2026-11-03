import Foundation
import Synchronization
import Testing

@testable import Core

private final class HTTPFixture: URLProtocol, @unchecked Sendable {
  struct Reply: Sendable {
    let status: Int
    let body: Data
    let headers: [String: String]
  }
  static let replies = Mutex<[String: Reply]>([:])
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host?.hasSuffix(".invalid") == true
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url, let reply = Self.replies.withLock({ $0[url.host ?? ""] }),
      let response = HTTPURLResponse(
        url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    for start in stride(from: 0, to: reply.body.count, by: 8192) {
      client?.urlProtocol(
        self, didLoad: reply.body.subdata(in: start..<min(start + 8192, reply.body.count)))
    }
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@Test func HTTPTransportPreservesErrorStatusAndHeaders() async throws {
  let host = UUID().uuidString + ".invalid"
  let url = try #require(URL(string: "https://" + host + "/file"))
  HTTPFixture.replies.withLock {
    $0[host] = .init(status: 429, body: Data("limited".utf8), headers: ["Retry-After": "2"])
  }
  defer { _ = HTTPFixture.replies.withLock { $0.removeValue(forKey: host) } }
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [HTTPFixture.self]
  let session = URLSession(configuration: configuration)
  defer { session.invalidateAndCancel() }
  let response = try await URLSessionHTTPTransport(session: session).send(URLRequest(url: url))
  #expect(response.status == 429)
  #expect(response.header("retry-after") == "2")
  #expect(response.body == Data("limited".utf8))
}

@Test func HTTPStreamReadsBoundedChunksAfterHeadersReturn() async throws {
  let host = UUID().uuidString + ".invalid"
  let url = try #require(URL(string: "https://" + host + "/file"))
  let expected = Data((0..<150_123).map { UInt8(truncatingIfNeeded: $0) })
  HTTPFixture.replies.withLock {
    $0[host] = .init(
      status: 206, body: expected, headers: ["Content-Range": "bytes 0-150122/150123"])
  }
  defer { _ = HTTPFixture.replies.withLock { $0.removeValue(forKey: host) } }
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [HTTPFixture.self]
  let session = URLSession(configuration: configuration)
  defer { session.invalidateAndCancel() }
  let response = try await URLSessionHTTPTransport(session: session).stream(URLRequest(url: url))
  #expect(response.response.status == 206)
  var output = Data()
  var sizes: [Int] = []
  for try await chunk in response.body {
    output.append(chunk)
    sizes.append(chunk.count)
  }
  #expect(output == expected)
  #expect(sizes == [65_536, 65_536, 19_051])
}

@Test func HTTPRedirectDoesNotForwardCredentialsOrBodiesOutsideTheirScope() throws {
  let source = URL(string: "https://drive-pc.quark.cn/file")!
  var request = URLRequest(url: URL(string: "https://cdn.example.invalid/file")!)
  request.setValue("test-cookie", forHTTPHeaderField: "Cookie")
  request.setValue("test-authorization", forHTTPHeaderField: "Authorization")
  let outside = try #require(
    HTTPRedirectPolicy.request(
      request, from: source, originalMethod: "GET", cookieDomain: "quark.cn"))
  #expect(outside.value(forHTTPHeaderField: "Cookie") == nil)
  #expect(outside.value(forHTTPHeaderField: "Authorization") == nil)
  #expect(
    HTTPRedirectPolicy.request(
      request, from: source, originalMethod: "POST", cookieDomain: "quark.cn") == nil)
  request.url = URL(string: "https://download.quark.cn/file")!
  let inside = try #require(
    HTTPRedirectPolicy.request(
      request, from: source, originalMethod: "GET", cookieDomain: "quark.cn"))
  #expect(inside.value(forHTTPHeaderField: "Cookie") == "test-cookie")
  #expect(inside.value(forHTTPHeaderField: "Authorization") == nil)
  request.url = URL(string: "https://quark.cn.attacker.invalid/file")!
  #expect(
    HTTPRedirectPolicy.request(
      request, from: source, originalMethod: "GET", cookieDomain: "quark.cn")?.value(
        forHTTPHeaderField: "Cookie") == nil)
  request.url = URL(string: "http://drive-pc.quark.cn/file")!
  #expect(
    HTTPRedirectPolicy.request(
      request, from: source, originalMethod: "GET", cookieDomain: "quark.cn") == nil)
}
