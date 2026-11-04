import Core
import Foundation
import Testing

@testable import ADB

actor LocalADBTransport: ADBTransport {
  let directory: URL
  let createTargetDuringMove: Bool
  let modern: Bool
  let uploadFailure: String?
  private var syncServices: Set<UInt32> = []
  private var uploadPath: URL?
  private(set) var uploadedPaths: [String] = []
  private(set) var events: [String] = []
  private var input = Data()
  private var outgoing = Data()
  private(set) var commands: [String] = []

  init(
    directory: URL, createTargetDuringMove: Bool = false, modern: Bool = true,
    uploadFailure: String? = nil
  ) {
    self.modern = modern
    self.uploadFailure = uploadFailure
    self.directory = directory
    self.createTargetDuringMove = createTargetDuringMove
  }

  func read(count: Int, timeout: TimeInterval) async throws -> Data {
    guard !input.isEmpty else { throw RemoteError.notConnected }
    let bytes = Data(input.prefix(count))
    input.removeFirst(bytes.count)
    return bytes
  }

  func write(_ data: Data, timeout: TimeInterval) async throws {
    outgoing.append(data)
    while outgoing.count >= 24 {
      var reader = BinaryReader(Data(outgoing[12..<16]))
      let size = 24 + Int(try reader.u32())
      guard outgoing.count >= size else { return }
      let message = try ADBMessage.decode(Data(outgoing.prefix(size)), skipChecksum: true)
      outgoing = Data(outgoing.dropFirst(size))
      if message.command == .connect {
        input.append(
          ADBMessage(
            .connect, 0x0100_0001, 1_048_576,
            payload: Data(
              ("device::features=" + (modern ? "shell_v2,sendrecv_v2" : "") + "\0").utf8)
          ).encoded())
      } else if message.command == .open {
        let service = String(decoding: message.payload.dropLast(), as: UTF8.self)
        if service == "sync:" {
          uploadPath = nil
          syncServices.insert(message.arg0)
          input.append(ADBMessage(.okay, 1, message.arg0).encoded())
          continue
        }
        let prefix = service.hasPrefix("shell,v2,raw:") ? "shell,v2,raw:" : "shell:"
        guard service.hasPrefix(prefix) else { throw RemoteError.protocolError }
        let command = String(service.dropFirst(prefix.count))
        commands.append(command)
        events.append("shell:" + command)
        let result =
          command.hasPrefix("for p in /storage/") ? (Data(), Int32(0)) : try execute(command)
        let local = message.arg0
        input.append(ADBMessage(.okay, 1, local).encoded())
        var output = Data([2])
        output.appendLE(UInt32(result.0.count))
        output.append(result.0)
        output.append(3)
        output.appendLE(1)
        output.append(UInt8(truncatingIfNeeded: result.1))
        input.append(
          ADBMessage(.write, 1, local, payload: prefix == "shell:" ? result.0 : output).encoded())
        input.append(ADBMessage(.close, 1, local).encoded())
      } else if message.command == .write, syncServices.contains(message.arg0) {
        try receiveSync(message)
      } else if message.command == .close, syncServices.remove(message.arg0) != nil {
        input.append(ADBMessage(.close, 1, message.arg0).encoded())
      }
    }
  }

  private func receiveSync(_ message: ADBMessage) throws {
    var reader = BinaryReader(message.payload)
    let id = try reader.u32()
    let value = try reader.u32()
    if id == ADBSync.id("SEND") || id == ADBSync.id("SND2"), uploadPath == nil {
      guard message.payload.count == Int(value) + 8 else { throw RemoteError.protocolError }
      var path = String(decoding: message.payload.suffix(Int(value)), as: UTF8.self)
      if id == ADBSync.id("SEND"), let comma = path.lastIndex(of: ",") {
        path = String(path[..<comma])
      }
      uploadedPaths.append(path)
      events.append("send:" + path)
      uploadPath = URL(filePath: path.replacingOccurrences(of: "/sdcard", with: directory.path))
      try Data().write(to: uploadPath!)
    } else if id == ADBSync.id("DATA") {
      guard let uploadPath, message.payload.count == Int(value) + 8 else {
        throw RemoteError.protocolError
      }
      let handle = try FileHandle(forWritingTo: uploadPath)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: message.payload.suffix(Int(value)))
      events.append("data")
      if uploadFailure == "interrupt" { throw RemoteError.notConnected }
    } else if id == ADBSync.id("DONE") {
      guard message.payload.count == 8 else { throw RemoteError.protocolError }
    } else {
      guard id == ADBSync.id("SND2"), message.payload.count == 12 else {
        throw RemoteError.protocolError
      }
    }
    input.append(ADBMessage(.okay, 1, message.arg0).encoded())
    if id == ADBSync.id("DONE") {
      events.append("done")
      var response = Data((uploadFailure == "server" ? "FAIL" : "OKAY").utf8)
      let text = uploadFailure == "server" ? Data("No space".utf8) : Data()
      response.appendLE(UInt32(text.count))
      response.append(text)
      input.append(ADBMessage(.write, 1, message.arg0, payload: response).encoded())
    }
  }

  private func execute(_ command: String) throws -> (Data, Int32) {
    let target = try ADBShell.quote(directory.appending(path: "target").path)
    let creation = createTargetDuringMove ? "printf 'late' > \(target)" : ":"
    // 用本地临时目录模拟 mv 的跳过语义，不执行设备路径或发现命令。
    let commitFailure =
      uploadFailure == "commit" ? "printf 'Permission denied\\n' >&2; return 1" : ":"
    let shim = """
      mv() {
        no_clobber=0; exact_target=0
        if [ "$1" = '-nT' ]; then no_clobber=1; exact_target=1; shift; fi
        if [ "$1" = '-T' ]; then exact_target=1; shift; fi
        if [ "$1" = '--' ]; then shift; fi
        \(commitFailure)
        if [ "$exact_target" = 1 ] && [ -d "$2" ]; then printf 'Is a directory\\n' >&2; return 1; fi
        \(creation)
        if [ "$no_clobber" = 1 ] && { [ -e "$2" ] || [ -L "$2" ]; }; then return 0; fi
        command /bin/mv "$1" "$2"
      }
      """
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.currentDirectoryURL = directory
    process.arguments = [
      "-c", shim + "\n" + command.replacingOccurrences(of: "/sdcard", with: directory.path),
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (output, process.terminationStatus)
  }

  func close() async {}
}

@Test(arguments: ["file", "directory", "symlink", "late"], [false, true])
func adbMoveRejectsExistingTargetsWithoutChangingSource(kind: String, modern: Bool) async throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appending(path: "source")
  let target = directory.appending(path: "target")
  try Data("original-source".utf8).write(to: source)
  switch kind {
  case "file": try Data("original-target".utf8).write(to: target)
  case "directory":
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
  case "symlink":
    try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: "missing")
  default: break
  }
  let transport = LocalADBTransport(
    directory: directory, createTargetDuringMove: kind == "late", modern: modern)
  let provider = ADBProvider(
    session: ADBSession(transport: transport, identity: ADBIdentity(store: MemorySecretStore())))
  try await provider.connect()
  await #expect(throws: RemoteError.posix(EEXIST)) {
    try await provider.move(RemotePath("/source"), to: RemotePath("/target"))
  }
  #expect(try Data(contentsOf: source) == Data("original-source".utf8))
  if kind == "file" { #expect(try Data(contentsOf: target) == Data("original-target".utf8)) }
  if kind == "late" { #expect(try Data(contentsOf: target) == Data("late".utf8)) }
  if kind == "symlink" {
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == "missing")
  }
}

@Test(arguments: [false, true])
func adbMoveQuotesPathsAndMovesToExactMissingTarget(modern: Bool) async throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = "照片 ' $(touch unexpected).txt"
  let target = "目标 😀.txt"
  try Data("contents".utf8).write(to: directory.appending(path: source))
  let transport = LocalADBTransport(directory: directory, modern: modern)
  let provider = ADBProvider(
    session: ADBSession(transport: transport, identity: ADBIdentity(store: MemorySecretStore())))
  try await provider.connect()
  try await provider.move(RemotePath("/" + source), to: RemotePath("/" + target))
  #expect(try Data(contentsOf: directory.appending(path: target)) == Data("contents".utf8))
  #expect(!FileManager.default.fileExists(atPath: directory.appending(path: source).path))
  #expect(await transport.commands.last?.contains("mv -nT --") == true)
  #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "unexpected").path))
}
