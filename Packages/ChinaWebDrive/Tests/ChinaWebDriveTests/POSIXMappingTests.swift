import Core
import Foundation
import Testing

@testable import ChinaWebDrive

private actor ErrorMappingHTTP: HTTPTransport {
  let phase: String
  var authorizations: [String] = []
  init(phase: String) { self.phase = phase }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    authorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
    if phase == "refresh" { return HTTPResponse(status: 401) }
    throw URLError(.timedOut)
  }
  func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
    if phase == "stream" { throw URLError(.timedOut) }
    return HTTPStreamResponse(
      response: HTTPResponse(status: 200),
      body: AsyncThrowingStream {
        $0.finish(throwing: URLError(.timedOut))
      })
  }
}

@Test(arguments: ["mobile", "xunlei"], ["send", "stream", "body", "refresh"])
func chinaWebNetworkErrorsRemainPOSIX(kind: String, phase: String) async throws {
  let transport = ErrorMappingHTTP(phase: phase)
  let mobile = MobileCloudSession(
    credentials: .init(phone: "local", token: "old"),
    refresh: { _ in throw URLError(.networkConnectionLost) }, transport: transport)
  let xunlei = XunleiSession(
    credentials: .init(accessToken: "old"),
    refresh: { _ in throw URLError(.networkConnectionLost) }, transport: transport)
  for _ in 0..<(phase == "refresh" ? 2 : 1) {
    do {
      if phase == "send" {
        if kind == "mobile" { try await mobile.connect() } else { try await xunlei.connect() }
      } else if phase == "refresh" {
        if kind == "mobile" {
          _ = try await mobile.accountRequest("disk/getPersonalDiskInfo", body: [:])
        } else {
          _ = try await xunlei.request(method: "GET", path: "about")
        }
      } else {
        let url = URL(string: "https://example.invalid/file")!
        let result =
          kind == "mobile"
          ? try await mobile.unsignedDownload(url, range: nil)
          : try await xunlei.download(url, range: nil)
        for try await _ in result.body {}
      }
      Issue.record("请求失败必须抛出")
    } catch {
      #expect((error as NSError).domain == NSPOSIXErrorDomain)
      #expect((error as NSError).code == Int(phase == "refresh" ? ECONNRESET : ETIMEDOUT))
    }
  }
  if phase == "refresh" {
    #expect(
      await transport.authorizations
        == Array(repeating: kind == "mobile" ? "Basic old" : "Token old", count: 2))
  }
}

@Test func chinaWebBusinessErrorsKeepTheirPOSIXMeaning() {
  let cases: [(any Error, Int32)] = [
    (MobileCloudError.invalidCredentials, EACCES), (MobileCloudError.loginRequired, EACCES),
    (MobileCloudError.invalidResponse, EIO), (XunleiError.invalidCredentials, EACCES),
    (XunleiError.loginRequired, EACCES), (XunleiError.invalidResponse, EIO),
    (XunleiError.unsupportedUploadProvider, ENOTSUP),
  ]
  for (error, code) in cases {
    #expect((error as NSError).domain == NSPOSIXErrorDomain)
    #expect((error as NSError).code == Int(code))
  }
}
