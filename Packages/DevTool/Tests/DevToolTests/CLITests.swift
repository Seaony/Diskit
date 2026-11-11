import Core
import Foundation
import Synchronization
import Testing

@testable import DevToolSupport

private final class Capture<Value: Sendable>: Sendable {
  private let storage: Mutex<Value>
  init(_ value: Value) { storage = Mutex(value) }
  func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
    storage.withLock { body(&$0) }
  }
}
private let identifier = "00000000-0000-0000-0000-000000000001"
private func item(
  _ path: String = "/file", name: String? = nil, size: Int64 = 3, directory: Bool = false
) throws -> RemoteItem {
  RemoteItem(
    path: try RemotePath(path), name: name ?? URL(fileURLWithPath: path).lastPathComponent,
    isDirectory: directory, size: size, modified: Date(timeIntervalSince1970: 0))
}
private actor FakeProvider: RemoteFileProvider {
  nonisolated let capabilities: ProviderCapabilities
  var events: [String] = []
  var entries: [RemoteItem]
  var chunks: [Data]
  var fail: Bool
  var onRead: (@Sendable () throws -> Void)?
  init(
    entries: [RemoteItem] = [], chunks: [Data] = [Data("abc".utf8)], range: Bool = true,
    fail: Bool = false, onRead: (@Sendable () throws -> Void)? = nil
  ) {
    self.entries = entries
    self.chunks = chunks
    self.fail = fail
    self.onRead = onRead
    capabilities = ProviderCapabilities(
      canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: range)
  }
  func connect() throws {
    events.append("connect")
    if fail { throw RemoteError.unauthorized }
  }
  func disconnect() { events.append("disconnect") }
  func spaceInfo() -> SpaceInfo { SpaceInfo(total: nil, used: nil) }
  func list(_ path: RemotePath) -> [RemoteItem] { entries.filter { $0.path != path } }
  func stat(_ path: RemotePath) throws -> RemoteItem {
    try entries.first { $0.path == path } ?? item(path.value)
  }
  func read(_ path: RemotePath, range: Range<Int64>?) throws -> AsyncThrowingStream<Data, Error> {
    events.append("read:\(range?.description ?? "all")")
    try onRead?()
    let data = chunks
    return AsyncThrowingStream { continuation in
      for chunk in data { continuation.yield(chunk) }
      continuation.finish()
    }
  }
  func write(_ path: RemotePath, from localFile: URL) { events.append("write:\(path)") }
  func makeDirectory(_ path: RemotePath) { events.append("mkdir:\(path)") }
  func remove(_ path: RemotePath, recursive: Bool) { events.append("rm:\(recursive)") }
  func move(_ from: RemotePath, to: RemotePath) { events.append("mv:\(to)") }
}
private func temporary() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
  return url
}
private struct TestStorageLocation: StorageLocation {
  let dataDirectory: URL
  var cacheDirectory: URL { dataDirectory.appending(path: "cache") }
}
private func execute(
  _ args: [String], provider: FakeProvider, output: Capture<[String]> = Capture([]),
  bytes: @escaping @Sendable (Data) throws -> Void = { _ in }
) async throws {
  try await CLIRunner.execute(
    CLIArguments(args), provider: provider, text: { value in output.withLock { $0.append(value) } },
    bytes: bytes, errors: { _ in })
}

@Test func argumentsPreservePositionsAndDashOperands() throws {
  #expect(try CLIArguments([]).command == "help")
  #expect(try CLIArguments(["--help"]).command == "help")
  #expect(try CLIArguments(["-h"]).command == "help")
  #expect(try CLIArguments(["devices"]).connectionID == nil)
  #expect(try CLIArguments(["pair", "host:1234", "123456"]).operands.count == 2)
  for args in [["ls", "-a", identifier, "/"], ["ls", identifier, "/", "-a"]] {
    #expect(try CLIArguments(args).showHidden)
  }
  #expect(try CLIArguments(["rm", identifier, "/x", "-r"]).recursive)
  #expect(try CLIArguments(["get", identifier, "/x", "-r"]).operands.last == "-r")
  #expect(try CLIArguments(["put", "--", identifier, "-a", "/x"]).operands.first == "-a")
  #expect(try CLIArguments(["cat", identifier, "/x", "--range", "1-2"]).range == 1..<3)
  for args in [
    ["wat"], ["df", "bad"], ["devices", "extra"], ["pair"], ["cat", identifier, "/", "--range"],
    ["cat", identifier, "/", "--range", "-1-2"], ["cat", identifier, "/", "--range", "3-1"],
    ["cat", identifier, "/", "--range", "0-9223372036854775807"],
    ["cat", identifier, "/", "--range", "0-1", "--range", "1-2"],
  ] {
    #expect(throws: RemoteError.self) { try CLIArguments(args) }
  }
}

@Test func environmentOnlyReadsExplicitFileAndDoesNotDamageURLs() throws {
  let empty = try CLIEnvironment.load([:]) { _ in
    Issue.record("不应读取默认配置")
    return ""
  }
  #expect(empty.value("absent", fallback: "fallback") == "fallback")
  let value = try CLIEnvironment.load(["KAYOI_SECRETS_FILE": "/fixture", "TOKEN": "override"]) {
    url in
    #expect(url.path == "/fixture")
    return
      "#comment\n//comment\nTOKEN = saved\nURL = https://example.invalid/a // comment\nQUOTED = \"a=b // c\"\nMACRO = https:/$()/host\n = ignored\ninvalid"
  }
  #expect(value.value("TOKEN") == "override")
  #expect(value.value("URL") == "https://example.invalid/a")
  #expect(value.value("QUOTED") == "a=b // c")
  #expect(value.value("MACRO") == "https://host")
}

@Test func connectionLoadingReadsSelectedStorageWithoutChangingEitherLocation() throws {
  let root = try temporary()
  defer { try? FileManager.default.removeItem(at: root) }
  let legacy = TestStorageLocation(dataDirectory: root.appending(path: "old"))
  let shared = TestStorageLocation(dataDirectory: root.appending(path: "shared"))
  let connection = Connection(id: UUID(uuidString: identifier)!, kind: .androidUSB, name: "手机")
  try ConnectionRepository(location: legacy).save([connection])
  let previous = try ConfigurationStore(location: legacy).read()
  #expect(try CLIRunner.loadConnection(connection.id, location: legacy) == connection)
  #expect(throws: RemoteError.self) {
    try CLIRunner.loadConnection(connection.id, location: shared)
  }
  #expect(try ConfigurationStore(location: legacy).read() == previous)
  #expect(try ConfigurationStore(location: shared).read() == nil)
  var migrated = connection
  migrated.name = "共享存储里的手机"
  try ConnectionRepository(location: shared).save([migrated])
  #expect(try CLIRunner.loadConnection(connection.id, location: shared) == migrated)
  #expect(try CLIRunner.loadConnection(connection.id, location: legacy) == connection)
  #expect(try ConfigurationStore(location: legacy).read() == previous)
}

@Test func listingAndErrorsDoNotLoseIdentityOrLeakSecrets() throws {
  #expect(CLIOutput.listLine(try item()) == "-\t3\tfile")
  #expect(CLIOutput.listLine(try item("/id'1", name: "display")) == "-\t3\tdisplay\t'/id'\\''1'")
  #expect(
    !CLIOutput.errorMessage(
      NSError(domain: "fixture", code: 3, userInfo: [NSLocalizedDescriptionKey: "secret-token"])
    ).contains("secret-token"))
  #expect(!CLIOutput.errorMessage(URLError(.timedOut)).isEmpty)
  #expect(!CLIOutput.errorMessage(POSIXError(.EEXIST)).isEmpty)
  #expect(!CLIOutput.errorMessage(RemoteError.invalidPath).isEmpty)
  #expect(CLIOutput.errorMessage(CancellationError()) == "操作已取消")
  #expect(try CLIRunner.pairingAddress("localhost:1234", code: "123456").1 == 1234)
  for host in ["host", "host:0", "host:65536", "user@host:1234", "host:1234/path"] {
    #expect(throws: RemoteError.self) { try CLIRunner.pairingAddress(host, code: "123456") }
  }
  #expect(throws: RemoteError.self) { try CLIRunner.pairingAddress("host:1234", code: "１２３４５６") }
}

@Test func routingDisconnectsAndHonorsHiddenAndRange() async throws {
  let provider = FakeProvider(entries: [try item(), try item("/.hidden")])
  let output = Capture<[String]>([])
  try await execute(["ls", identifier, "/"], provider: provider, output: output)
  #expect(output.withLock { $0.count } == 1)
  try await execute(["ls", "-a", identifier, "/"], provider: provider, output: output)
  #expect(output.withLock { $0.count } == 3)
  for args in [
    ["stat", identifier, "/file"], ["df", identifier], ["mkdir", identifier, "/new"],
    ["rm", "-r", identifier, "/file"], ["mv", identifier, "/file", "/renamed"],
    ["mv", identifier, "/file", "/dir/file"],
  ] { try await execute(args, provider: provider, output: output) }
  #expect(output.withLock { $0.contains("total=unknown used=unknown available=unknown") })
  for ranged in [false, true] {
    let source = FakeProvider(chunks: [Data((ranged ? "bc" : "abc").utf8)], range: ranged)
    let bytes = Capture(Data())
    try await execute(
      ["cat", identifier, "/file", "--range", "1-2"], provider: source,
      bytes: { value in bytes.withLock { $0.append(value) } })
    #expect(bytes.withLock { $0 } == Data("bc".utf8))
  }
  do {
    try await execute(
      ["cat", identifier, "/file"], provider: provider,
      bytes: { _ in throw RemoteError.protocolError })
    Issue.record("应传播输出错误")
  } catch {}
  #expect(await provider.events.last == "disconnect")
  let failure = FakeProvider(fail: true)
  do {
    try await execute(["df", identifier], provider: failure)
    Issue.record("应传播连接错误")
  } catch {}
  #expect(await failure.events == ["connect", "disconnect"])
}

@Test func downloadPreservesExistingFilesAndCleansPartialResults() async throws {
  let root = try temporary()
  defer { try? FileManager.default.removeItem(at: root) }
  let destination = root.appending(path: "target")
  try Data("original".utf8).write(to: destination)
  let provider = FakeProvider()
  do {
    try await CLITransfers.download(
      provider, remote: RemotePath("/file"), local: destination, report: { _, _ in })
    Issue.record("应拒绝覆盖")
  } catch {}
  #expect(try Data(contentsOf: destination) == Data("original".utf8))
  try FileManager.default.removeItem(at: destination)
  for chunks in [[Data("a".utf8)], [Data("abcd".utf8)]] {
    do {
      try await CLITransfers.download(
        FakeProvider(chunks: chunks), remote: RemotePath("/file"), local: destination,
        report: { _, _ in })
      Issue.record("应拒绝不完整长度")
    } catch {}
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }
  try await execute(["get", identifier, "/file", destination.path], provider: provider)
  #expect(try Data(contentsOf: destination) == Data("abc".utf8))
  try FileManager.default.removeItem(at: destination)
  let race = FakeProvider(onRead: { try Data("other".utf8).write(to: destination) })
  do {
    try await CLITransfers.download(
      race, remote: RemotePath("/file"), local: destination, report: { _, _ in })
    Issue.record("应拒绝并发覆盖")
  } catch {}
  #expect(try Data(contentsOf: destination) == Data("other".utf8))
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["target"])
}

@Test func recursiveTransfersRejectUnsafeNamesAndSymlinks() async throws {
  let root = try temporary()
  defer { try? FileManager.default.removeItem(at: root) }
  let directory = try item("/dir", size: 0, directory: true)
  let destination = root.appending(path: "target")
  let provider = FakeProvider(entries: [directory, try item("/dir/file")])
  try await CLITransfers.download(
    provider, remote: directory.path, local: destination, report: { _, _ in })
  #expect(try Data(contentsOf: destination.appending(path: "file")) == Data("abc".utf8))
  try await execute(["put", identifier, destination.path, "/upload"], provider: provider)
  #expect(await provider.events.contains("write:/upload/file"))
  try FileManager.default.removeItem(at: destination)
  let bad = FakeProvider(entries: [directory, try item("/dir/id", name: "../escape")])
  do {
    try await CLITransfers.download(
      bad, remote: directory.path, local: destination, report: { _, _ in })
    Issue.record("应拒绝越界名称")
  } catch {}
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  try FileManager.default.createSymbolicLink(
    at: destination, withDestinationURL: root.appending(path: "missing"))
  do {
    try await CLITransfers.download(
      provider, remote: directory.path, local: destination, report: { _, _ in })
    Issue.record("应拒绝悬空链接")
  } catch {}
  do {
    try await CLITransfers.upload(
      provider, local: destination, remote: directory.path, report: { _, _ in })
    Issue.record("应拒绝上传符号链接")
  } catch {}
}

@Test func providerConstructionUsesOnlyInjectedCredentials() async throws {
  let secrets = MemorySecretStore()
  let environment = CLIEnvironment(values: [
    "GOOGLE_CLIENT_ID": "fixture.apps.googleusercontent.com"
  ])
  let kinds: [ConnectionKind] = [
    .aliyunDrive, .quark, .ucDrive, .baiduDrive, .drive115, .drive123, .oneDrive, .googleDrive,
    .dropbox, .pikPak, .tianyiDrive, .mobileCloud, .thunderDrive, .s3, .cloudflareR2, .aliyunOSS,
    .tencentCOS, .qiniuKodo, .minIO, .backblazeB2,
  ]
  for kind in kinds {
    let connection = Connection(
      kind: kind,
      params: [
        "endpoint": "https://example.invalid", "bucket": "fixture", "accessKey": "fixture",
        "phone": "13800000000",
      ])
    try secrets.write(Data("fixture".utf8), for: connection.passwordKey)
    _ = try await CLIProviderFactory.make(connection, values: environment, secrets: secrets)
  }
  _ = try await CLIProviderFactory.make(
    Connection(kind: .tianyiDrive, params: ["scope": "family", "familyID": "fixture"]),
    values: environment, secrets: secrets)
  for kind in [
    ConnectionKind.baiduDrive, .drive115, .drive123, .oneDrive, .googleDrive, .dropbox, .smb,
  ] {
    let config = CLIProviderFactory.oauthConfiguration(kind, values: environment)
    if [.oneDrive, .googleDrive, .dropbox].contains(kind) {
      #expect(config.clientSecret.isEmpty)
      #expect(config.usesPKCE)
    }
  }
  do {
    _ = try await CLIProviderFactory.make(
      Connection(kind: .smb), values: environment, secrets: secrets)
    Issue.record("应拒绝未实现类型")
  } catch {}
}

@Test func downloadRejectsDuplicateNamesAndCancellationAndAllowsEmptyFiles() async throws {
  let root = try temporary()
  defer { try? FileManager.default.removeItem(at: root) }
  let destination = root.appending(path: "target")
  let empty = FakeProvider(entries: [try item(size: 0)], chunks: [])
  try await CLITransfers.download(
    empty, remote: RemotePath("/file"), local: destination, report: { _, _ in })
  #expect(try Data(contentsOf: destination).isEmpty)
  try FileManager.default.removeItem(at: destination)
  let directory = try item("/dir", size: 0, directory: true)
  let duplicate = FakeProvider(entries: [
    directory, try item("/dir/a", name: "same"), try item("/dir/b", name: "same"),
  ])
  do {
    try await CLITransfers.download(
      duplicate, remote: directory.path, local: destination, report: { _, _ in })
    Issue.record("应拒绝重复展示名称")
  } catch {}
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  let cancelled = FakeProvider(onRead: { throw CancellationError() })
  do {
    try await CLITransfers.download(
      cancelled, remote: RemotePath("/file"), local: destination, report: { _, _ in })
    Issue.record("应传播取消")
  } catch { #expect(error is CancellationError) }
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func progressIncludesUnknownAndCompleteTotals() {
  let output = Capture<[String]>([])
  let progress = CLIProgress { value in output.withLock { $0.append(value) } }
  progress.report(1, total: nil)
  progress.report(2, total: nil)
  progress.report(3, total: 3)
  #expect(output.withLock { $0.first?.contains("1 / ? bytes") } == true)
  #expect(output.withLock { $0.last?.contains("3 / 3 bytes") } == true)
}

@Test(arguments: [false, true])
func downloadsReportEachChunkRegardlessOfRangeCapability(range: Bool) async throws {
  let root = try temporary()
  defer { try? FileManager.default.removeItem(at: root) }
  let provider = FakeProvider(chunks: [Data("a".utf8), Data("bc".utf8)], range: range)
  let progress = Mutex<[Int64]>([])
  try await CLITransfers.download(
    provider, remote: RemotePath("/file"), local: root.appending(path: "download"),
    report: { completed, _ in progress.withLock { $0.append(completed) } })
  #expect(progress.withLock { $0 } == [1, 3, 3])
}
