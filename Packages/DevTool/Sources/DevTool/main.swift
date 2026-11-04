import ADB
import AliyunDrive
import CameraUSB
import ChinaWebDrive
import CloudDrive
import Core
import Foundation
import LanzouDrive
import PikPakDrive
import Quark
import RicohGR
import S3Drive
import Synchronization
import TianyiDrive

private let help = """
  kayoi-dev — Kayoi 开发工具
    devices                            列出安卓与 USB 相机
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

private let secretsFileValues = loadSecretsFile()

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
    if let aliyun = provider as? AliyunProvider {
      await aliyun.onProgress { progress.report($0, total: $1) }
    }
    if let quark = provider as? QuarkProvider {
      await quark.onProgress { progress.report($0, total: $1) }
    }
    if let pikPak = provider as? PikPakProvider {
      await pikPak.onProgress { progress.report($0, total: $1) }
    }
    if let tianyi = provider as? TianyiProvider {
      await tianyi.onProgress { progress.report($0, total: $1) }
    }
    if let mobile = provider as? MobileCloudProvider {
      await mobile.onProgress { progress.report($0, total: $1) }
    }
    if let s3 = provider as? S3Provider {
      await s3.onProgress { progress.report($0, total: $1) }
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
    for device in try await RicohDiscovery.available() {
      print("ricohGR\t\(device.serial)\t\(device.name)")
    }
    for device in (try? await CameraUSBDiscovery.available()) ?? [] {
      print("cameraUSB\t\(device.serial)\t\(device.name)")
    }
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
  if (connection.kind == .ricohGR || connection.kind == .cameraUSB)
    && ["put", "mkdir", "mv"].contains(command)
  {
    throw RemoteError.posix(EROFS)
  }
  if connection.kind == .lanzou && ["put", "mkdir", "mv", "rm"].contains(command) {
    throw RemoteError.posix(EROFS)
  }
  let provider: any RemoteFileProvider
  switch connection.kind {
  case .androidUSB, .androidWiFi: provider = try await ADBProviderFactory.make(for: connection)
  case .ricohGR: provider = try await RicohProvider.make(serial: connection.params["serial"] ?? "")
  case .cameraUSB:
    provider = try await CameraUSBProvider.make(identifier: connection.params["serial"] ?? "")
  case .aliyunDrive:
    provider = AliyunProvider(
      session: AliyunSession(
        secretKey: "\(connection.id.uuidString).oauth", configuration: AliyunConfiguration()))
  case .quark:
    provider = QuarkProvider(
      session: QuarkSession(
        secretKey: "\(connection.id.uuidString).cookie", configuration: .quark))
  case .ucDrive:
    provider = QuarkProvider(
      session: QuarkSession(
        secretKey: "\(connection.id.uuidString).cookie", configuration: .uc))
  case .baiduDrive:
    provider = BaiduDriveProvider(
      configuration: BaiduDriveConfiguration(
        rootPath: environment("BAIDU_ROOT_PATH", fallback: "apps/Kayoi"),
        appID: environment("BAIDU_APP_ID")),
      session: OAuthSession(
        configuration: oauthConfiguration(.baiduDrive), secretKey: oauthKey(connection)))
  case .drive115:
    provider = Drive115Provider(
      session: OAuthSession(
        configuration: oauthConfiguration(.drive115), secretKey: oauthKey(connection)))
  case .drive123:
    provider = Drive123Provider(
      session: OAuthSession(
        configuration: oauthConfiguration(.drive123), secretKey: oauthKey(connection)))
  case .oneDrive:
    provider = OneDriveProvider(
      session: OAuthSession(
        configuration: oauthConfiguration(.oneDrive), secretKey: oauthKey(connection)))
  case .googleDrive:
    provider = GoogleDriveProvider(
      session: OAuthSession(
        configuration: oauthConfiguration(.googleDrive), secretKey: oauthKey(connection)))
  case .dropbox:
    provider = DropboxProvider(
      session: OAuthSession(
        configuration: oauthConfiguration(.dropbox), secretKey: oauthKey(connection)))
  case .pikPak:
    provider = PikPakProvider(
      session: PikPakSession(secretKey: "\(connection.id.uuidString).oauth.pikPak"))
  case .tianyiDrive:
    let configuration =
      connection.params["scope"] == "family"
      ? TianyiConfiguration.family(familyID: connection.params["familyID"] ?? "")
      : TianyiConfiguration.personal
    provider = TianyiProvider(
      session: TianyiSession(
        secretKey: "\(connection.id.uuidString).oauth.tianyiDrive",
        configuration: configuration))
  case .lanzou:
    let secret = try savedSecret(connection)
    let authentication: LanzouAuthentication
    if connection.params["authMode"] == "share" {
      guard let url = URL(string: connection.params["shareURL"] ?? "") else {
        throw ConnectionError.invalidFields
      }
      authentication = .share(url: url, password: secret.isEmpty ? nil : secret)
    } else {
      authentication = .accountCookie(secret)
    }
    provider = LanzouProvider(
      configuration: try LanzouConfiguration(authentication: authentication))
  case .mobileCloud:
    provider = MobileCloudProvider(
      session: MobileCloudSession(
        credentials: MobileCloudCredentials(
          phone: connection.params["phone"] ?? "", token: try savedSecret(connection),
          userDomainID: connection.params["userDomainID"])))
  case .thunderDrive:
    provider = XunleiProvider(
      session: XunleiSession(
        credentials: XunleiCredentials(accessToken: try savedSecret(connection))))
  case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2:
    guard let endpoint = URL(string: connection.params["endpoint"] ?? "") else {
      throw ConnectionError.invalidFields
    }
    let secret =
      try LoginKeychainStore().read(connection.passwordKey).map {
        String(decoding: $0, as: UTF8.self)
      } ?? ""
    provider = S3Provider(
      configuration: S3Configuration(
        endpoint: endpoint, region: connection.params["region"] ?? "us-east-1",
        bucket: connection.params["bucket"] ?? "", accessKey: connection.params["accessKey"] ?? "",
        secretKey: secret, pathStyle: connection.params["pathStyle"] != "false"))
  default: throw ConnectionError.notImplemented
  }
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
      let requestedRange = provider.capabilities.supportsRangeRead ? range : nil
      var offset: Int64 = requestedRange?.lowerBound ?? 0
      for try await bytes in try await provider.read(RemotePath(args[0]), range: requestedRange) {
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

private func environment(_ name: String, fallback: String = "") -> String {
  ProcessInfo.processInfo.environment[name] ?? secretsFileValues[name] ?? fallback
}

private func loadSecretsFile() -> [String: String] {
  let environment = ProcessInfo.processInfo.environment
  var candidates: [URL] = []
  if let override = environment["KAYOI_SECRETS_FILE"] {
    candidates.append(URL(fileURLWithPath: override))
  }
  let working = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  candidates.append(working.appending(path: "Config/Secrets.xcconfig"))
  var executableFolder = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
  for _ in 0..<8 {
    candidates.append(executableFolder.appending(path: "Config/Secrets.xcconfig"))
    executableFolder.deleteLastPathComponent()
  }
  guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
    let text = try? String(contentsOf: url, encoding: .utf8)
  else {
    return [:]
  }
  var values: [String: String] = [:]
  for rawLine in text.components(separatedBy: .newlines) {
    let line =
      rawLine.components(separatedBy: "//").first?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else {
      continue
    }
    let key = String(line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines))
    var value = line[line.index(after: equals)...]
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "$()", with: "")
    if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
      value.removeFirst()
      value.removeLast()
    }
    guard !key.isEmpty else { continue }
    values[key] = value
  }
  return values
}

private func savedSecret(_ connection: Connection) throws -> String {
  try LoginKeychainStore().read(connection.passwordKey).map {
    String(decoding: $0, as: UTF8.self)
  } ?? ""
}

private func oauthKey(_ connection: Connection) -> String {
  "\(connection.id.uuidString).oauth.\(connection.kind.rawValue)"
}

private func oauthConfiguration(_ kind: ConnectionKind) -> OAuthConfiguration {
  switch kind {
  case .baiduDrive:
    return OAuthConfiguration(
      clientID: environment("BAIDU_CLIENT_ID"),
      clientSecret: environment("BAIDU_CLIENT_SECRET"),
      authorizationURL: URL(string: "https://openapi.baidu.com/oauth/2.0/authorize")!,
      tokenURL: URL(string: "https://openapi.baidu.com/oauth/2.0/token")!,
      redirectURI: environment("BAIDU_REDIRECT_URI"),
      scopes: ["basic", "netdisk"], scopeSeparator: ",",
      tokenRequestMethod: "GET", tokenRequestPlacement: .query)
  case .drive115:
    return OAuthConfiguration(
      clientID: environment("DRIVE115_CLIENT_ID"),
      clientSecret: environment("DRIVE115_CLIENT_SECRET"),
      authorizationURL: URL(string: "https://passportapi.115.com/open/authorize")!,
      tokenURL: URL(string: "https://passportapi.115.com/open/authCodeToToken")!,
      refreshTokenURL: URL(string: "https://passportapi.115.com/open/refreshToken")!,
      redirectURI: environment("DRIVE115_REDIRECT_URI"), scopes: [],
      tokenResponseDataKey: "data", refreshGrantIncludesClientCredentials: false)
  case .drive123:
    return OAuthConfiguration(
      clientID: environment("DRIVE123_CLIENT_ID"),
      clientSecret: environment("DRIVE123_CLIENT_SECRET"),
      authorizationURL: URL(string: "https://yun.123pan.com/auth")!,
      tokenURL: URL(string: "https://open-api.123pan.com/api/v1/oauth2/access_token")!,
      redirectURI: environment("DRIVE123_REDIRECT_URI"),
      scopes: ["user:base", "file:all:read", "file:all:write"], scopeSeparator: ",")
  case .oneDrive:
    return OAuthConfiguration(
      clientID: environment("ONEDRIVE_CLIENT_ID"),
      clientSecret: environment("ONEDRIVE_CLIENT_SECRET"),
      authorizationURL: URL(
        string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
      tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
      redirectURI: environment("ONEDRIVE_REDIRECT_URI"),
      scopes: ["offline_access", "User.Read", "Files.ReadWrite"])
  case .googleDrive:
    return OAuthConfiguration(
      clientID: environment("GOOGLE_CLIENT_ID"),
      clientSecret: environment("GOOGLE_CLIENT_SECRET"),
      authorizationURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
      tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
      redirectURI: environment("GOOGLE_REDIRECT_URI"),
      scopes: ["openid", "email", "profile", "https://www.googleapis.com/auth/drive"],
      additionalAuthorizationItems: ["access_type": "offline", "prompt": "consent"])
  case .dropbox:
    return OAuthConfiguration(
      clientID: environment("DROPBOX_CLIENT_ID"),
      clientSecret: environment("DROPBOX_CLIENT_SECRET"),
      authorizationURL: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
      tokenURL: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
      redirectURI: environment("DROPBOX_REDIRECT_URI"),
      scopes: [
        "account_info.read", "files.content.read", "files.content.write",
        "files.metadata.read", "files.metadata.write",
      ],
      additionalAuthorizationItems: ["token_access_type": "offline"])
  default:
    return OAuthConfiguration(
      clientID: "", clientSecret: "",
      authorizationURL: URL(string: "https://example.invalid/authorize")!,
      tokenURL: URL(string: "https://example.invalid/token")!,
      redirectURI: "", scopes: [])
  }
}

do { try await run(Array(CommandLine.arguments.dropFirst())) } catch {
  try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
  exit(1)
}
