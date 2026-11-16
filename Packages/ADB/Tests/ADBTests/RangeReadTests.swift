import Core
import Foundation
import Testing

@testable import ADB

// 用本机 sh 和 dd 跑真实命令，逐字节核对范围读：跨块、块边界、最后不满一块、文件末尾
@Test func adbRangeReadReturnsExactBytes() async throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let bytes = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 9) })
  let name = "视频 'a' $(x).bin"
  try bytes.write(to: directory.appending(path: name))
  let transport = LocalADBTransport(directory: directory)
  let provider = ADBProvider(
    session: ADBSession(transport: transport, identity: ADBIdentity(store: MemorySecretStore())))
  try await provider.connect()
  func read(_ range: Range<Int64>) async throws -> Data {
    var result = Data()
    for try await chunk in try await provider.read(RemotePath("/" + name), range: range) {
      result.append(chunk)
    }
    return result
  }
  let ranges: [Range<Int64>] = [
    0..<1, 0..<65_536, 65_535..<65_537, 65_536..<131_072, 100..<150_000, 131_072..<131_073,
    196_607..<200_000, 199_999..<200_000,
  ]
  for range in ranges {
    #expect(try await read(range) == bytes[Int(range.lowerBound)..<Int(range.upperBound)])
  }
  // 文件在 stat 之后变短：只返回到文件末尾
  #expect(try await read(150_000..<250_000) == bytes[150_000...])
  #expect(try await read(300_000..<300_010).isEmpty)
  #expect(
    await transport.commands.contains(
      "dd if='/sdcard/视频 '\\''a'\\'' $(x).bin' bs=65536 skip=0 count=2 status=none"))
  await #expect(throws: RemoteError.posix(ENOENT)) {
    _ = try await provider.read(RemotePath("/missing"), range: 0..<10)
  }
  #expect(try await read(0..<4) == bytes.prefix(4))
}
