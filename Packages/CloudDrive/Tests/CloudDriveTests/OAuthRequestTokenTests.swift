import Foundation
import Testing

@testable import CloudDrive

@Test func oauthTokenReplacementPreservesUnrelatedEncodedFields() throws {
  var request = URLRequest(
    url: URL(
      string: "https://example.com/file?path=a%2fb+z&access_token=old%2Btoken&empty=")!)
  request.setValue(
    "application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
  request.httpBody = Data("name=a%2fb+z&access_token=old%2Btoken&&empty=".utf8)
  #expect(OAuthRequestToken.read(from: request) == "old+token")
  let retry = OAuthRequestToken.replacing(in: request, with: "new+token &")
  #expect(
    retry.url?.absoluteString
      == "https://example.com/file?path=a%2fb+z&access_token=new%2Btoken%20%26&empty=")
  #expect(retry.httpBody == Data("name=a%2fb+z&access_token=new%2Btoken%20%26&&empty=".utf8))
  request.url = URL(string: "https://example.com/file")!
  #expect(OAuthRequestToken.read(from: request) == "old+token")
  request.httpBody = Data("access_token=old+token".utf8)
  #expect(OAuthRequestToken.read(from: request) == "old token")
}

@Test func oauthTokenReplacementDoesNotInterpretUnrelatedBodies() {
  for contentType in [
    "application/json", "multipart/form-data; boundary=boundary", "application/octet-stream",
  ] {
    var request = URLRequest(url: URL(string: "https://example.com/file?path=a%2fb")!)
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    request.httpBody = Data("access_token=file-content".utf8)
    #expect(OAuthRequestToken.read(from: request) == nil)
    #expect(OAuthRequestToken.replacing(in: request, with: "fresh") == request)
  }
}
