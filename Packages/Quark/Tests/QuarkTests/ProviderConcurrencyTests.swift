import Core
import Foundation
import Testing

@testable import Quark

private actor DirectoryRaceHTTP: HTTPTransport {
  private let holdAt: Int
  private var lists = 0
  private var pending: CheckedContinuation<HTTPResponse, Never>?
  private var pendingResponse: HTTPResponse?
  private var ready: CheckedContinuation<Void, Never>?
  var name: String? = "old"
  private(set) var deletions = 0

  init(holdAt: Int) { self.holdAt = holdAt }
  func setName(_ value: String?) { name = value }
  func waitUntilHeld() async {
    if pending != nil { return }
    await withCheckedContinuation { ready = $0 }
  }
  func resume() {
    if let pendingResponse { pending?.resume(returning: pendingResponse) }
    pending = nil
    pendingResponse = nil
  }
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    let path = request.url?.path ?? ""
    if path == "/account/info" {
      return HTTPResponse(
        status: 200, body: Data(#"{"success":true,"data":{"nickname":"local","uid":"local"}}"#.utf8)
      )
    }
    if path == "/1/clouddrive/member" {
      return HTTPResponse(
        status: 200,
        body: Data(#"{"status":200,"code":0,"data":{"total_capacity":10,"use_capacity":1}}"#.utf8))
    }
    if path == "/1/clouddrive/file/delete" {
      deletions += 1
      name = nil
      return HTTPResponse(status: 200, body: Data(#"{"status":200,"code":0,"data":{}}"#.utf8))
    }
    guard path == "/1/clouddrive/file/sort" else { return HTTPResponse(status: 404) }
    lists += 1
    let entries: [[String: Any]] =
      name.map { [["fid": $0, "file_name": $0, "file": true, "size": 1, "updated_at": 0]] } ?? []
    let response = HTTPResponse(
      status: 200,
      body: try JSONSerialization.data(withJSONObject: [
        "status": 200, "code": 0, "data": ["list": entries], "metadata": ["_total": entries.count],
      ]))
    if lists == holdAt {
      return await withCheckedContinuation {
        pending = $0
        pendingResponse = response
        ready?.resume()
        ready = nil
      }
    }
    return response
  }
}

private func raceProvider(_ http: DirectoryRaceHTTP) throws -> QuarkProvider {
  let secrets = MemorySecretStore()
  try secrets.write(Data("__puus=local; __pus=local".utf8), for: "local")
  return QuarkProvider(session: QuarkSession(secretKey: "local", secrets: secrets, transport: http))
}

@Test func quarkLateListingCannotUndoDeletion() async throws {
  let http = DirectoryRaceHTTP(holdAt: 2)
  let provider = try raceProvider(http)
  try await provider.connect()
  _ = try await provider.list(RemotePath("/"))
  let stale = Task { try await provider.list(RemotePath("/")) }
  await http.waitUntilHeld()
  try await provider.remove(RemotePath("/old"), recursive: false)
  await http.resume()
  await #expect(throws: RemoteError.posix(EAGAIN)) { _ = try await stale.value }
  await #expect(throws: RemoteError.posix(ENOENT)) {
    try await provider.remove(RemotePath("/old"), recursive: false)
  }
  #expect(await http.deletions == 1)
}

@Test func quarkLatestListingWinsAndDisconnectRejectsLateReplies() async throws {
  for disconnect in [false, true] {
    let http = DirectoryRaceHTTP(holdAt: 1)
    let provider = try raceProvider(http)
    try await provider.connect()
    let stale = Task { try await provider.list(RemotePath("/")) }
    await http.waitUntilHeld()
    await http.setName("new")
    if disconnect {
      await provider.disconnect()
    } else {
      #expect(try await provider.list(RemotePath("/")).map(\.name) == ["new"])
    }
    await http.resume()
    await #expect(throws: RemoteError.posix(EAGAIN)) { _ = try await stale.value }
    if disconnect { try await provider.connect() }
    await #expect(throws: RemoteError.posix(ENOENT)) {
      try await provider.remove(RemotePath("/old"), recursive: false)
    }
    #expect(await http.deletions == 0)
  }
}
