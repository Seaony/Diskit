import Core
import Foundation
import Testing

@testable import ADB

@Test(arguments: [false, true], ["interrupt", "server", "commit"])
func adbFailedUploadKeepsOriginal(modern: Bool, failure: String) async throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let target = directory.appending(path: "target")
  let source = directory.appending(path: "local")
  try Data("original".utf8).write(to: target)
  try Data("replacement".utf8).write(to: source)
  let transport = LocalADBTransport(directory: directory, modern: modern, uploadFailure: failure)
  let provider = ADBProvider(
    session: ADBSession(transport: transport, identity: ADBIdentity(store: MemorySecretStore())))
  try await provider.connect()
  let expected: RemoteError =
    failure == "interrupt" ? .notConnected : .posix(failure == "server" ? ENOSPC : EACCES)
  await #expect(throws: expected) {
    try await provider.write(RemotePath("/target"), from: source)
  }
  #expect(try Data(contentsOf: target) == Data("original".utf8))
  #expect(await transport.uploadedPaths.count == 1)
  #expect(await transport.uploadedPaths.allSatisfy { $0 != "/sdcard/target" })
  if failure != "interrupt" {
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == [
        "local", "target",
      ])
  }
}

@Test(arguments: [false, true], ["", "replacement"])
func adbUploadPublishesOnlyAfterCompletion(modern: Bool, contents: String) async throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let name = "照片 ' 😀.txt"
  let target = directory.appending(path: name)
  let source = directory.appending(path: "local")
  try Data("original".utf8).write(to: target)
  try Data(contents.utf8).write(to: source)
  let transport = LocalADBTransport(directory: directory, modern: modern)
  let provider = ADBProvider(
    session: ADBSession(transport: transport, identity: ADBIdentity(store: MemorySecretStore())))
  try await provider.connect()
  try await provider.write(RemotePath("/" + name), from: source)
  #expect(try Data(contentsOf: target) == Data(contents.utf8))
  let events = await transport.events
  let complete = try #require(events.firstIndex(of: "done"))
  let publish = try #require(
    events.firstIndex { $0.hasPrefix("shell:") && $0.contains("mv -T --") })
  #expect(complete < publish)
  #expect(await transport.uploadedPaths.allSatisfy { $0 != "/sdcard/" + name })
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
}

@Test func adbCancellationBeforePublishKeepsOriginal() async throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let target = directory.appending(path: "target")
  let source = directory.appending(path: "local")
  try Data("original".utf8).write(to: target)
  try Data("replacement".utf8).write(to: source)
  let transport = LocalADBTransport(directory: directory)
  let provider = ADBProvider(
    session: ADBSession(transport: transport, identity: ADBIdentity(store: MemorySecretStore())))
  try await provider.connect()
  await provider.onProgress { _, _ in withUnsafeCurrentTask { $0?.cancel() } }
  let task = Task { try await provider.write(RemotePath("/target"), from: source) }
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(try Data(contentsOf: target) == Data("original".utf8))
  #expect(await !transport.commands.contains { $0.contains("mv -T --") })
}

@Test(arguments: [false, true])
func adbUploadNeverMovesTemporaryFileInsideTargetDirectory(modern: Bool) async throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  let target = directory.appending(path: "target")
  try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appending(path: "local")
  try Data("replacement".utf8).write(to: source)
  let transport = LocalADBTransport(directory: directory, modern: modern)
  let provider = ADBProvider(
    session: ADBSession(transport: transport, identity: ADBIdentity(store: MemorySecretStore())))
  try await provider.connect()
  await #expect(throws: (any Error).self) {
    try await provider.write(RemotePath("/target"), from: source)
  }
  #expect(await transport.uploadedPaths.count == 1)
  #expect(await transport.commands.contains { $0.contains("mv -T --") })
  #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == [
      "local", "target",
    ])
}
