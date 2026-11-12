import Core
import Foundation
import Synchronization
import Testing

@testable import CloudDrive

private final class ExpiryHTTP: HTTPTransport, Sendable {
  let requests = Mutex<[URLRequest]>([])
  let reply: @Sendable (URLRequest) throws -> HTTPResponse
  init(_ reply: @escaping @Sendable (URLRequest) throws -> HTTPResponse) { self.reply = reply }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.withLock { $0.append(request) }
    return try reply(request)
  }
}

private func expiryReply(_ text: String, status: Int = 200) -> HTTPResponse {
  HTTPResponse(status: status, body: Data(text.utf8))
}

private func expirySession(_ transport: any HTTPTransport) throws -> OAuthSession {
  let secrets = MemorySecretStore()
  try secrets.write(
    JSONEncoder().encode(OAuthToken(accessToken: "old", refreshToken: "refresh", expiresAt: .distantFuture)),
    for: "expiry")
  return OAuthSession(
    configuration: OAuthConfiguration(
      clientID: "local", clientSecret: "", authorizationURL: URL(string: "https://local.invalid/auth")!,
      tokenURL: URL(string: "https://local.invalid/token")!, redirectURI: "diskit://local", scopes: []),
    secretKey: "expiry", secrets: secrets, transport: transport)
}

private func expiryQuery(_ request: URLRequest) -> [String: String] {
  Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

@Test(arguments: ["single", "initiate", "part", "complete"])
func drive115ExpiredCredentialsResignOnlyRejectedUploadStep(stage: String) async throws {
  let tokens = Mutex(0)
  let http = ExpiryHTTP { request in
    switch request.url?.path {
    case "/open/user/info": return expiryReply(#"{"state":true,"data":{"user_id":1,"user_name":"Local"}}"#)
    case "/open/ufile/files": return expiryReply(#"{"state":true,"count":0,"data":[]}"#)
    case "/open/upload/init":
      return expiryReply(#"{"state":true,"data":{"status":1,"bucket":"bucket","object":"object","callback":{"callback":"{}","callback_var":"{}"}}}"#)
    case "/open/upload/get_token":
      let number = tokens.withLock { $0 += 1; return $0 }
      return expiryReply("{\"state\":true,\"data\":{\"endpoint\":\"https://oss.example.invalid\",\"AccessKeyId\":\"key\(number)\",\"AccessKeySecret\":\"secret\",\"SecurityToken\":\"token\(number)\"}}")
    case "/object":
      let query = expiryQuery(request)
      let current = request.value(forHTTPHeaderField: "x-oss-security-token")
      let matches = stage == "single" || (stage == "initiate" && query["uploads"] != nil)
        || (stage == "part" && query["partNumber"] == "2")
        || (stage == "complete" && request.httpMethod == "POST" && query["uploadId"] != nil)
      if current == "token1", matches {
        return expiryReply("<Error><Code>SecurityTokenExpired</Code></Error>", status: 403)
      }
      if query["uploads"] != nil { return expiryReply("<InitiateMultipartUploadResult><UploadId>upload</UploadId></InitiateMultipartUploadResult>") }
      if query["partNumber"] != nil { return HTTPResponse(status: 200, headers: ["ETag": "part-" + query["partNumber"]!]) }
      return expiryReply("{}")
    default: throw RemoteError.protocolError
    }
  }
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try Data([1, 2]).write(to: file)
  defer { try? FileManager.default.removeItem(at: file) }
  let provider = Drive115Provider(session: try expirySession(http), transport: http, multipartThreshold: stage == "single" ? 10 : 0, partSize: 1)
  try await provider.connect()
  try await provider.write(RemotePath("/new"), from: file)
  #expect(tokens.withLock { $0 } == 2)
  let requests = http.requests.withLock { $0 }
  #expect(requests.filter { $0.url?.path == "/open/upload/init" }.count == 1)
  #expect(!requests.contains { $0.httpMethod == "DELETE" })
  if stage == "part" {
    let parts = requests.filter { expiryQuery($0)["partNumber"] != nil }
    #expect(parts.map { expiryQuery($0)["partNumber"]! } == ["1", "2", "2"])
    #expect(parts.allSatisfy { expiryQuery($0)["uploadId"] == "upload" })
    try #require(parts.count == 3)
    #expect(parts[1].httpBody == parts[2].httpBody)
    #expect(parts[1].value(forHTTPHeaderField: "Authorization") != parts[2].value(forHTTPHeaderField: "Authorization"))
  }
}

@Test(arguments: ["AccessDenied", "InvalidSecurityToken", "SecurityTokenExpired"])
func drive115UploadCredentialRecoveryIsBoundedAndDoesNotRetryPermissions(code: String) async throws {
  let tokens = Mutex(0)
  let uploads = Mutex(0)
  let http = ExpiryHTTP { request in
    switch request.url?.path {
    case "/open/user/info": return expiryReply(#"{"state":true,"data":{"user_id":1,"user_name":"Local"}}"#)
    case "/open/ufile/files": return expiryReply(#"{"state":true,"count":0,"data":[]}"#)
    case "/open/upload/init": return expiryReply(#"{"state":true,"data":{"status":1,"bucket":"bucket","object":"object","callback":{"callback":"{}","callback_var":"{}"}}}"#)
    case "/open/upload/get_token":
      tokens.withLock { $0 += 1 }
      return expiryReply(#"{"state":true,"data":{"endpoint":"https://oss.example.invalid","AccessKeyId":"key","AccessKeySecret":"secret","SecurityToken":"token"}}"#)
    case "/object":
      uploads.withLock { $0 += 1 }
      return expiryReply("<Error><Code>\(code)</Code></Error>", status: 403)
    default: throw RemoteError.protocolError
    }
  }
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try Data([1]).write(to: file)
  defer { try? FileManager.default.removeItem(at: file) }
  let provider = Drive115Provider(session: try expirySession(http), transport: http)
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EACCES)) { try await provider.write(RemotePath("/new"), from: file) }
  #expect(tokens.withLock { $0 } == (code == "SecurityTokenExpired" ? 2 : 1))
  #expect(uploads.withLock { $0 } == (code == "SecurityTokenExpired" ? 2 : 1))
}

@Test(arguments: [false, true])
func drive123ExpiredAccessTokenRetriesSameSliceWithoutRestarting(businessCode: Bool) async throws {
  let http = ExpiryHTTP { request in
    switch request.url?.path {
    case "/api/v1/user/info": return expiryReply(#"{"code":0,"data":{"uid":1,"nickname":"Local","headImage":"","spaceUsed":0,"spacePermanent":100,"spaceTemp":0}}"#)
    case "/api/v2/file/list": return expiryReply(#"{"code":0,"data":{"lastFileId":-1,"fileList":[]}}"#)
    case "/upload/v2/file/create": return expiryReply(#"{"code":0,"data":{"fileID":0,"reuse":false,"preuploadID":"original","sliceSize":1,"servers":["https://upload.example.invalid"]}}"#)
    case "/upload/v2/file/slice":
      let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
      if body.contains("name=\"sliceNo\"\r\n\r\n2\r\n"), request.value(forHTTPHeaderField: "Authorization") == "Bearer old" {
        return expiryReply(#"{"code":401}"#, status: businessCode ? 200 : 401)
      }
      return expiryReply(#"{"code":0,"data":{}}"#)
    case "/token": return expiryReply(#"{"access_token":"fresh","refresh_token":"rotated","expires_in":3600}"#)
    case "/upload/v2/file/upload_complete": return expiryReply(#"{"code":0,"data":{"completed":true,"fileID":8}}"#)
    default: throw RemoteError.protocolError
    }
  }
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try Data([1, 2]).write(to: file)
  defer { try? FileManager.default.removeItem(at: file) }
  let provider = Drive123Provider(session: try expirySession(http), transport: http)
  try await provider.connect()
  try await provider.write(RemotePath("/new"), from: file)
  let requests = http.requests.withLock { $0 }
  let slices = requests.filter { $0.url?.path == "/upload/v2/file/slice" }
  try #require(slices.count == 3)
  #expect(slices[1].httpBody == slices[2].httpBody)
  #expect(slices[2].value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
  #expect(requests.filter { $0.url?.path == "/upload/v2/file/create" }.count == 1)
  #expect(requests.filter { $0.url?.path == "/token" }.count == 1)
}

@Test(arguments: [false, true])
func baiduExpiredAccessTokenRetriesSamePartWithoutRestarting(businessCode: Bool) async throws {
  let first = Data(repeating: 1, count: 4 * 1024 * 1024)
  let last = Data([2])
  let http = ExpiryHTTP { request in
    let query = expiryQuery(request)
    if request.url?.path == "/token" { return expiryReply(#"{"access_token":"fresh","refresh_token":"rotated","expires_in":3600}"#) }
    switch query["method"] {
    case "uinfo": return expiryReply(#"{"errno":0,"uk":1,"vip_type":0}"#)
    case "list": return expiryReply(#"{"errno":0,"list":[]}"#)
    case "precreate": return expiryReply(#"{"errno":0,"uploadid":"original","block_list":[0,1],"return_type":1}"#)
    case "upload":
      if query["partseq"] == "1", query["access_token"] == "old" {
        return expiryReply(#"{"error_code":31045}"#, status: businessCode ? 200 : 401)
      }
      let hash = CloudDriveSupport.md5Hex(query["partseq"] == "0" ? first : last)
      return expiryReply("{\"md5\":\"\(hash)\"}")
    case "create": return expiryReply(#"{"errno":0,"fs_id":8}"#)
    default: throw RemoteError.protocolError
    }
  }
  let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try (first + last).write(to: file)
  defer { try? FileManager.default.removeItem(at: file) }
  let provider = BaiduDriveProvider(configuration: BaiduDriveConfiguration(rootPath: "/apps/local", appID: "local"), session: try expirySession(http), transport: http)
  try await provider.connect()
  try await provider.write(RemotePath("/new"), from: file)
  let requests = http.requests.withLock { $0 }
  let parts = requests.filter { expiryQuery($0)["method"] == "upload" }
  #expect(parts.map { expiryQuery($0)["partseq"]! } == ["0", "1", "1"])
  #expect(parts.allSatisfy { expiryQuery($0)["uploadid"] == "original" })
  try #require(parts.count == 3)
  #expect(parts[1].httpBody == parts[2].httpBody)
  #expect(expiryQuery(parts[2])["access_token"] == "fresh")
  #expect(requests.filter { expiryQuery($0)["method"] == "precreate" }.count == 1)
  #expect(requests.filter { $0.url?.path == "/token" }.count == 1)
}
