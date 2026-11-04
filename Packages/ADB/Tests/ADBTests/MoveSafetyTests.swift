import Core
import Foundation
import Testing

@testable import ADB

private actor LocalShellTransport: ADBTransport {
  let directory: URL
  let createTargetDuringMove: Bool
  private var input = Data()
  private var outgoing = Data()
  private(set) var commands: [String] = []

  init(directory: URL, createTargetDuringMove: Bool = false) {
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
            payload: Data("device::features=shell_v2\0".utf8)
          ).encoded())
      } else if message.command == .open {
        let service = String(decoding: message.payload.dropLast(), as: UTF8.self)
        guard service.hasPrefix("shell,v2,raw:") else { throw RemoteError.protocolError }
        let command = String(service.dropFirst("shell,v2,raw:".count))
        commands.append(command)
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
        input.append(ADBMessage(.write, 1, local, payload: output).encoded())
        input.append(ADBMessage(.close, 1, local).encoded())
      }
    }
  }

  private func execute(_ command: String) throws -> (Data, Int32) {
    let target = try ADBShell.quote(directory.appending(path: "target").path)
    let creation = createTargetDuringMove ? "printf 'late' > \(target)" : ":"
    // 用本地临时目录模拟 mv 的跳过语义，不执行设备路径或发现命令。
    let shim = """
      mv() {
        no_clobber=0
        if [ "$1" = '-nT' ]; then no_clobber=1; shift; fi
        if [ "$1" = '--' ]; then shift; fi
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

@Test(arguments: ["file", "directory", "symlink", "late"])
func adbMoveRejectsExistingTargetsWithoutChangingSource(kind: String) async throws {
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
  let transport = LocalShellTransport(directory: directory, createTargetDuringMove: kind == "late")
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

@Test func adbMoveQuotesPathsAndMovesToExactMissingTarget() async throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = "照片 ' $(touch unexpected).txt"
  let target = "目标 😀.txt"
  try Data("contents".utf8).write(to: directory.appending(path: source))
  let transport = LocalShellTransport(directory: directory)
  let provider = ADBProvider(
    session: ADBSession(transport: transport, identity: ADBIdentity(store: MemorySecretStore())))
  try await provider.connect()
  try await provider.move(RemotePath("/" + source), to: RemotePath("/" + target))
  #expect(try Data(contentsOf: directory.appending(path: target)) == Data("contents".utf8))
  #expect(!FileManager.default.fileExists(atPath: directory.appending(path: source).path))
  #expect(await transport.commands.last?.contains("mv -nT --") == true)
  #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "unexpected").path))
}
