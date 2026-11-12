import Core
import Darwin
import Dispatch
import Foundation
import Testing

@testable import CloudDrive

private final class ProcessTestBundle: NSObject {}

private struct ProcessSecrets: SecretStore {
  let directory: URL
  let role: String

  func refreshLockLocation(for key: String) -> URL { directory.appending(path: "refresh.lock") }
  func read(_ key: String) throws -> Data? {
    let url = directory.appending(path: "credential.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    if try JSONDecoder().decode(OAuthToken.self, from: data).accessToken == "old" {
      try Data().write(to: directory.appending(path: "read-" + role), options: .atomic)
    }
    return data
  }
  func write(_ data: Data, for key: String) throws {
    try data.write(to: directory.appending(path: "credential.json"), options: .atomic)
  }
  func delete(_ key: String) throws {
    let url = directory.appending(path: "credential.json")
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }
}

private func waitForProcessFixture(in directory: URL, _ condition: @Sendable () -> Bool) async throws {
  let descriptor = open(directory.path, O_EVTONLY)
  guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
  let source = DispatchSource.makeFileSystemObjectSource(
    fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .global())
  let (events, continuation) = AsyncStream<Void>.makeStream()
  source.setEventHandler { continuation.yield(()) }
  source.setCancelHandler { close(descriptor) }
  source.resume()
  defer {
    source.cancel()
    continuation.finish()
  }
  try await withTaskCancellationHandler {
    // 先监听再检查，避免文件刚写入时错过通知。
    if condition() { return }
    for await _ in events {
      try Task.checkCancellation()
      if condition() { return }
    }
    try Task.checkCancellation()
  } onCancel: {
    continuation.finish()
  }
}

private struct ProcessRefreshHTTP: HTTPTransport {
  let directory: URL
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    guard request.url?.host == "refresh.invalid" else { throw RemoteError.protocolError }
    if request.url?.path == "/files" {
      guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh" else {
        return HTTPResponse(status: 401)
      }
      return HTTPResponse(status: 200)
    }
    guard request.url?.path == "/token" else { throw RemoteError.protocolError }
    let event = directory.appending(path: "refresh-" + UUID().uuidString)
    try Data().write(to: event)
    // 两个进程都已读取旧记录，才允许首个刷新完成。
    try await waitForProcessFixture(in: directory) {
      ["one", "two"].allSatisfy {
        FileManager.default.fileExists(atPath: directory.appending(path: "read-" + $0).path)
      }
    }
    let marker = directory.appending(path: "rotated")
    let fd = open(marker.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    guard fd >= 0 else {
      return HTTPResponse(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
    }
    close(fd)
    return HTTPResponse(
      status: 200,
      body: Data(
        #"{"access_token":"fresh","refresh_token":"rotated","expires_in":3600}"#.utf8))
  }
}

@Test func processesCoordinateOAuthRefresh() async throws {
  let environment = ProcessInfo.processInfo.environment
  if let path = environment["DISKIT_REFRESH_FIXTURE_DIRECTORY"],
    let role = environment["DISKIT_REFRESH_FIXTURE_ROLE"]
  {
    let directory = URL(filePath: path)
    let session = OAuthSession(
      configuration: OAuthConfiguration(
        clientID: "fixture", clientSecret: "fixture",
        authorizationURL: URL(string: "https://refresh.invalid/authorize")!,
        tokenURL: URL(string: "https://refresh.invalid/token")!, redirectURI: "diskit://fixture",
        scopes: []),
      secretKey: "account", secrets: ProcessSecrets(directory: directory, role: role),
      transport: ProcessRefreshHTTP(directory: directory))
    #expect(
      try await session.authorized(URLRequest(url: URL(string: "https://refresh.invalid/files")!))
        .status == 200)
    #expect(try await session.hasToken())
    return
  }

  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try ProcessSecrets(directory: directory, role: "parent").write(
    JSONEncoder().encode(
      OAuthToken(accessToken: "old", refreshToken: "old-refresh", expiresAt: .distantPast)),
    for: "account")
  let bundle = try #require(Bundle(for: ProcessTestBundle.self).executableURL)
  let package = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  let (exits, exitContinuation) = AsyncStream<Int>.makeStream()
  defer { exitContinuation.finish() }
  var children: [Process] = []
  var logs: [FileHandle] = []
  defer {
    for child in children where child.isRunning {
      child.terminate()
      child.waitUntilExit()
    }
    for log in logs { try? log.close() }
  }
  for (index, role) in ["one", "two"].enumerated() {
    let child = Process()
    child.executableURL = URL(filePath: CommandLine.arguments[0])
    child.arguments = [
      "--test-bundle-path", bundle.path, "--package-path", package.path,
      "--filter", "processesCoordinateOAuthRefresh", bundle.path, "--testing-library",
      "swift-testing",
    ]
    var childEnvironment = environment
    childEnvironment["DISKIT_REFRESH_FIXTURE_DIRECTORY"] = directory.path
    childEnvironment["DISKIT_REFRESH_FIXTURE_ROLE"] = role
    child.environment = childEnvironment
    let logURL = directory.appending(path: role + ".log")
    try Data().write(to: logURL)
    let log = try FileHandle(forWritingTo: logURL)
    logs.append(log)
    child.standardOutput = log
    child.standardError = log
    child.terminationHandler = { _ in exitContinuation.yield(index) }
    try child.run()
    children.append(child)
  }
  var completed = 0
  for await index in exits {
    completed += 1
    if children[index].terminationStatus != 0 {
      for child in children where child.isRunning { child.terminate() }
    }
    if completed == children.count { break }
  }
  try Task.checkCancellation()
  for (index, child) in children.enumerated() {
    child.waitUntilExit()
    let log = try String(
      contentsOf: directory.appending(path: index == 0 ? "one.log" : "two.log"), encoding: .utf8)
    #expect(child.terminationStatus == 0, "子进程输出：\(log)")
  }
  let events = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
    $0.hasPrefix("refresh-")
  }
  #expect(events.count == 1)
  let saved = try JSONDecoder().decode(
    OAuthToken.self, from: Data(contentsOf: directory.appending(path: "credential.json")))
  #expect(saved.accessToken == "fresh" && saved.refreshToken == "rotated")
}
