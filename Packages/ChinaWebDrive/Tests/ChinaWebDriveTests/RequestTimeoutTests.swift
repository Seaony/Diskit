import Foundation
import Testing

@testable import ChinaWebDrive

@Test func chinaWebMetadataRequestUsesThirtySeconds() throws {
  let request = try ChinaWebSupport.jsonRequest(
    URL(string: "https://example.invalid/api")!, json: ["id": "local"])
  #expect(request.timeoutInterval == 30)
  #expect(request.httpMethod == "POST")
  #expect(request.httpBody == Data(#"{"id":"local"}"#.utf8))
}
