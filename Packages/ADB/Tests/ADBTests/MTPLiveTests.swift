import Core
import Foundation
import Testing

@testable import ADB

// 真机测试：插着开了文件传输的安卓设备时手动跑。
// DISKIT_MTP_LIVE=1 只读；再加 DISKIT_MTP_LIVE_WRITE=1 会在设备根目录建一个“Diskit 测试”文件夹，测完删掉
private let live = ProcessInfo.processInfo.environment["DISKIT_MTP_LIVE"] == "1"
private let liveWrite = ProcessInfo.processInfo.environment["DISKIT_MTP_LIVE_WRITE"] == "1"

private func elapsed(_ start: ContinuousClock.Instant) -> String {
  let duration = start.duration(to: .now)
  return String(format: "%.3fs", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
}

@Test(.enabled(if: live)) func liveMTPDevice() async throws {
  let devices = MTPUSB.devices()
  print("发现 MTP 设备：", devices)
  let device = try #require(devices.first)
  let connection = Connection(
    kind: .androidMTP, name: device.name, params: device.connectionParameters(in: devices))
  let mtp = MTPProvider.make(for: connection)
  var start = ContinuousClock.now
  try await mtp.connect()
  print("连接用时", elapsed(start))
  print("容量", try await mtp.spaceInfo())
  start = .now
  let root = try await mtp.list(RemotePath("/"))
  print("根目录 \(root.count) 项，用时 \(elapsed(start))：", root.map { ($0.isDirectory ? "📁" : "") + $0.name })
  var top = try RemotePath("/")
  if root.count > 0, root.allSatisfy(\.isDirectory), root.count <= 3 {
    // 多个存储时根目录是存储名
    top = root[0].path
  }
  for folder in try await mtp.list(top) where folder.isDirectory {
    start = .now
    let items = try await mtp.list(folder.path)
    print("  \(folder.name)：\(items.count) 项，用时 \(elapsed(start))")
  }
  // 找一个文件读一下开头和整个文件；按层往下找，最多看 200 个文件夹
  var queue = [top]
  var sample: RemoteItem?
  var visited = 0
  while sample == nil, !queue.isEmpty, visited < 200 {
    let next = queue.removeFirst()
    visited += 1
    let items = try await mtp.list(next)
    sample = items.first { !$0.isDirectory && $0.size > 0 }
    queue += items.filter(\.isDirectory).map(\.path)
  }
  // 设备上一个文件都没找到就算失败，不能什么都没读就通过
  let found = try #require(sample, "设备上没找到可读的文件")
  sample = found
  if let sample {
    let item = try await mtp.stat(sample.path)
    print("样本文件", item.path, item.size, item.modified)
    var head = Data()
    for try await chunk in try await mtp.read(sample.path, range: 0..<min(65_536, item.size)) {
      head.append(chunk)
    }
    #expect(Int64(head.count) == min(65_536, item.size))
    start = .now
    var total = 0
    for try await chunk in try await mtp.read(sample.path, range: nil) { total += chunk.count }
    #expect(Int64(total) == item.size)
    let seconds = Double(start.duration(to: .now).components.seconds) + Double(start.duration(to: .now).components.attoseconds) / 1e18
    print("整读 \(total) 字节，用时 \(elapsed(start))，\(String(format: "%.1f", Double(total) / max(seconds, 0.001) / 1_000_000)) MB/s")
  }
  if liveWrite {
    // 只删本轮建的文件夹；上次中断留下的只提示，不按名字前缀去删设备上的东西
    for leftover in try await mtp.list(top) where leftover.isDirectory && leftover.name.hasPrefix("Diskit 测试 ") {
      print("设备上有上次留下的测试文件夹，请手动确认后删除：", leftover.name)
    }
    let folder = try top.appending("Diskit 测试 " + UUID().uuidString.prefix(8))
    try await mtp.makeDirectory(folder)
    let content = Data((0..<3_000_000).map { UInt8($0 % 251) })
    let local = FileManager.default.temporaryDirectory.appending(path: "diskit-mtp-live")
    try content.write(to: local)
    let file = try folder.appending("中文 文件.bin")
    start = .now
    try await mtp.write(file, from: local)
    print("上传 3 MB 用时", elapsed(start))
    var back = Data()
    for try await chunk in try await mtp.read(file, range: nil) { back.append(chunk) }
    #expect(back == content)
    // 覆盖已有文件：和卷后端一样，传到暂存名、删旧文件、暂存改成原名
    try Data("替换后的内容".utf8).write(to: local)
    await #expect(throws: RemoteError.posix(EEXIST)) { try await mtp.write(file, from: local) }
    let staging = try folder.appending(".中文 文件.bin.diskit-upload-1")
    try await mtp.write(staging, from: local)
    try await mtp.remove(file, recursive: false)
    try await mtp.move(staging, to: file)
    #expect(try await mtp.stat(file).size == Int64(Data("替换后的内容".utf8).count))
    #expect(try await mtp.list(folder).map(\.name) == ["中文 文件.bin"])
    // 测上传速度
    let big = Data((0..<30_000_000).map { UInt8($0 % 241) })
    try big.write(to: local)
    start = .now
    try await mtp.write(try folder.appending("30MB.bin"), from: local)
    let upload = Double(start.duration(to: .now).components.seconds) + Double(start.duration(to: .now).components.attoseconds) / 1e18
    print("上传 30 MB 用时 \(elapsed(start))，\(String(format: "%.1f", 30.0 / max(upload, 0.001))) MB/s")
    start = .now
    var downloaded = Data()
    for try await chunk in try await mtp.read(try folder.appending("30MB.bin"), range: nil) { downloaded.append(chunk) }
    #expect(downloaded == big)
    print("读回 30 MB 用时", elapsed(start))
    try await mtp.remove(try folder.appending("30MB.bin"), recursive: false)
    // 改名、建子文件夹、移动
    let renamed = try folder.appending("改名.txt")
    try await mtp.move(file, to: renamed)
    let sub = try folder.appending("子文件夹")
    try await mtp.makeDirectory(sub)
    try await mtp.move(renamed, to: sub.appending("改名.txt"))
    #expect(try await mtp.list(sub).map(\.name) == ["改名.txt"])
    await #expect(throws: RemoteError.posix(ENOTEMPTY)) { try await mtp.remove(folder, recursive: false) }
    try await mtp.remove(folder, recursive: true)
    await #expect(throws: RemoteError.posix(ENOENT)) { _ = try await mtp.stat(folder) }
    print("写入测试通过，测试文件夹已删除")
  }
  await mtp.disconnect()
}
