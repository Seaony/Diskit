import ADB
import Core
import Foundation
import Synchronization

private let help = """
  kayoi-dev — Kayoi 开发工具
    devices                            列出安卓与 GR 设备
    pair <host:port> <配对码>            无线配对
    ls [-a] <连接ID> <路径>              列目录
    stat <连接ID> <路径>                 文件信息
    get <连接ID> <远端> <本地>            下载文件或目录
    put <连接ID> <本地> <远端>            上传文件或目录
    mkdir <连接ID> <路径>                新建目录
    rm [-r] <连接ID> <路径>              删除
    mv <连接ID> <源> <目标>              移动或改名
    df <连接ID>                         容量
    cat [--range <起>-<止>] <连接ID> <路径>  输出文件，范围含两端
  """

final class Progress: Sendable {
  private let start = Date()
  private let last = Mutex<Date>(.distantPast)
  func report(_ bytes: Int64, total: Int64?, finished: Bool = false) {
    let now = Date()
    let emit = last.withLock { last in
      guard finished || now.timeIntervalSince(last) >= 0.5 else { return false }
      last = now
      return true
    }
    guard emit else { return }
    let rate = Double(bytes) / max(0.001, now.timeIntervalSince(start)) / 1_000_000
    let text =
      "\(bytes) / \(total.map(String.init) ?? "?") bytes · \(String(format: "%.2f", rate)) MB/s\n"
    try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
  }
}

func upload(_ provider: any RemoteFileProvider, local: URL, remote: RemotePath) async throws {
  let values = try local.resourceValues(forKeys: [
    .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
  ])
  guard values.isSymbolicLink != true else { throw RemoteError.unsupported }
  if values.isDirectory == true {
    try await provider.makeDirectory(remote)
    for child in try FileManager.default.contentsOfDirectory(
      at: local, includingPropertiesForKeys: nil)
    {
      try await upload(provider, local: child, remote: remote.appending(child.lastPathComponent))
    }
  } else {
    let progress = Progress()
    if let adb = provider as? ADBProvider {
      await adb.onProgress { progress.report($0, total: $1) }
    }
    try await provider.write(remote, from: local)
    progress.report(Int64(values.fileSize ?? 0), total: Int64(values.fileSize ?? 0), finished: true)
  }
}

func download(_ provider: any RemoteFileProvider, remote: RemotePath, local: URL) async throws {
  let info = try await provider.stat(remote)
  if info.isDirectory {
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    for child in try await provider.list(remote) {
      guard child.name != ".", child.name != "..", !child.name.contains("/") else {
        throw RemoteError.invalidPath
      }
      try await download(provider, remote: child.path, local: local.appending(path: child.name))
    }
  } else {
    guard FileManager.default.createFile(atPath: local.path, contents: nil) else {
      throw RemoteError.posix(EACCES)
    }
    let handle = try FileHandle(forWritingTo: local)
    defer { try? handle.close() }
    let progress = Progress()
    var count: Int64 = 0
    for try await chunk in try await provider.read(remote, range: nil) {
      try handle.write(contentsOf: chunk)
      count += Int64(chunk.count)
      progress.report(count, total: info.size)
    }
    progress.report(count, total: info.size, finished: true)
  }
}

func run(_ arguments: [String]) async throws {
  if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
    print(help)
    return
  }
  var args = arguments
  let command = args.removeFirst()
  if command == "devices" {
    for device in ADBUSB.devices() { print("androidUSB\t\(device.serial)\t\(device.name)") }
    return
  }
  if command == "pair" {
    guard args.count == 2, let address = URLComponents(string: "adb://" + args[0]),
      let host = address.host, let rawPort = address.port, let port = UInt16(exactly: rawPort)
    else { throw RemoteError.invalidPath }
    print(try await ADBPairing.pair(host: host, port: port, code: args[1]))
    return
  }
  let recursive = args.contains("-r")
  args.removeAll { $0 == "-r" || $0 == "-a" }
  var range: Range<Int64>?
  if let index = args.firstIndex(of: "--range") {
    guard index + 1 < args.count else { throw RemoteError.invalidPath }
    let parts = args[index + 1].split(separator: "-")
    guard parts.count == 2, let lower = Int64(parts[0]), let upper = Int64(parts[1]), lower >= 0,
      upper >= lower, upper < Int64.max
    else { throw RemoteError.invalidPath }
    range = lower..<(upper + 1)
    args.removeSubrange(index...index + 1)
  }
  guard let first = args.first, let id = UUID(uuidString: first),
    let connection = try ConnectionRepository().load().first(where: { $0.id == id })
  else { throw RemoteError.invalidPath }
  args.removeFirst()
  let required = [
    "ls": 1, "stat": 1, "get": 2, "put": 2, "mkdir": 1, "rm": 1, "mv": 2, "df": 0, "cat": 1,
  ]
  guard required[command] == args.count else { throw RemoteError.invalidPath }
  guard connection.kind == .androidUSB || connection.kind == .androidWiFi else {
    throw ConnectionError.notImplemented
  }
  let provider = try await ADBProviderFactory.make(for: connection)
  do {
    try await provider.connect()
    switch command {
    case "ls":
      for item in try await provider.list(RemotePath(args[0])) {
        print("\(item.isDirectory ? "d" : "-")\t\(item.size)\t\(item.name)")
      }
    case "stat":
      let item = try await provider.stat(RemotePath(args[0]))
      print(
        "\(item.path)\t\(item.size)\t\(item.modified)\t\(item.isDirectory ? "directory" : "file")")
    case "mkdir": try await provider.makeDirectory(RemotePath(args[0]))
    case "rm": try await provider.remove(RemotePath(args[0]), recursive: recursive)
    case "mv": try await provider.move(RemotePath(args[0]), to: RemotePath(args[1]))
    case "put":
      try await upload(provider, local: URL(fileURLWithPath: args[0]), remote: RemotePath(args[1]))
    case "get":
      try await download(
        provider, remote: RemotePath(args[0]), local: URL(fileURLWithPath: args[1]))
    case "df":
      let space = try await provider.spaceInfo()
      print("total=\(space.total) used=\(space.used) available=\(space.available)")
    case "cat":
      var offset: Int64 = 0
      for try await bytes in try await provider.read(RemotePath(args[0]), range: nil) {
        let next = offset + Int64(bytes.count)
        if let range {
          let lower = max(offset, range.lowerBound)
          let upper = min(next, range.upperBound)
          if lower < upper {
            try FileHandle.standardOutput.write(
              contentsOf: bytes.subdata(in: Int(lower - offset)..<Int(upper - offset)))
          }
          if next >= range.upperBound { break }
        } else {
          try FileHandle.standardOutput.write(contentsOf: bytes)
        }
        offset = next
      }
    default: throw RemoteError.unsupported
    }
    await provider.disconnect()
  } catch {
    await provider.disconnect()
    throw error
  }
}

do { try await run(Array(CommandLine.arguments.dropFirst())) } catch {
  try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
  exit(1)
}
