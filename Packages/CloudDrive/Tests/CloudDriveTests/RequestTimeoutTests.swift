import Foundation
import Testing

@testable import CloudDrive

@Test func cloudMetadataRequestsUseThirtySeconds() throws {
  let url = URL(string: "https://example.invalid/api")!
  let json = try CloudDriveSupport.jsonRequest(url, method: "POST", json: ["id": "local"])
  let form = CloudDriveSupport.formRequest(url, fields: ["id": "local"])
  #expect(json.timeoutInterval == 30)
  #expect(form.timeoutInterval == 30)
  #expect(json.httpMethod == "POST")
  #expect(form.httpBody == Data("id=local".utf8))
}

@Test func multipartMetadataDoesNotUseUploadTimeout() {
  var form = MultipartFormData()
  form.addText("id", "local")
  let request = CloudDriveSupport.multipartRequest(
    URL(string: "https://example.invalid/api")!, form: form)
  #expect(request.timeoutInterval == 30)
  #expect(request.httpBody == form.finished())
}

@Test func multipartFileUsesSixtySecondIdleInterval() {
  var form = MultipartFormData()
  form.addText("id", "local")
  form.addFile("file", filename: "local.bin", data: Data([1, 2, 3]))
  let request = CloudDriveSupport.multipartRequest(
    URL(string: "https://example.invalid/upload")!, form: form)
  #expect(request.timeoutInterval == 60)
  #expect(request.httpBody == form.finished())
}
