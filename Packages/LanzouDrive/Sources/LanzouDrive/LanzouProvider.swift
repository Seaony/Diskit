import Core
import Foundation

public actor LanzouProvider: RemoteFileProvider {
  private enum Backing: Hashable, Sendable {
    case accountFolder(String)
    case accountFile(String)
    case sharePage(URL)
  }

  private struct Node: Sendable {
    let item: RemoteItem
    let backing: Backing
  }

  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: false, canRename: false, canMove: false, canDelete: false, supportsRangeRead: true)

  private let configuration: LanzouConfiguration
  private let session: LanzouSession
  private var connected = false
  private var nodes: [String: Node] = [:]
  private var generation = UUID()
  private var directoryLoads: [String: UUID] = [:]
  private var downloadURLs: [Backing: URL] = [:]
  private var downloadTasks: [Backing: Task<URL, Error>] = [:]

  public init(
    configuration: LanzouConfiguration,
    transport: any HTTPTransport = URLSessionHTTPTransport()
  ) {
    self.init(session: LanzouSession(configuration: configuration, transport: transport))
  }

  public init(session: LanzouSession) {
    self.configuration = session.configuration
    self.session = session
  }

  public func connect() async throws {
    let operation = UUID()
    generation = operation
    connected = false
    nodes.removeAll()
    directoryLoads.removeAll()
    downloadURLs.removeAll()
    for task in downloadTasks.values { task.cancel() }
    downloadTasks.removeAll()
    try await session.connect()
    guard generation == operation else { throw CancellationError() }
    connected = true
  }

  public func disconnect() async {
    generation = UUID()
    connected = false
    nodes.removeAll()
    directoryLoads.removeAll()
    downloadURLs.removeAll()
    for task in downloadTasks.values { task.cancel() }
    downloadTasks.removeAll()
  }

  public func spaceInfo() async throws -> SpaceInfo {
    try requireConnection()
    throw RemoteError.unsupported
  }

  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    try requireConnection()
    let node = try await resolve(path)
    return try await directoryContents(node).map(\.item)
  }

  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    try requireConnection()
    return try await resolve(path).item
  }

  public func read(
    _ path: RemotePath, range: Range<Int64>?
  ) async throws -> AsyncThrowingStream<Data, Error> {
    try requireConnection()
    let operation = generation
    let node = try await resolve(path)
    guard !node.item.isDirectory else { throw RemoteError.posix(EISDIR) }
    if let range {
      guard range.lowerBound >= 0, range.upperBound >= range.lowerBound else {
        throw RemoteError.posix(EINVAL)
      }
      if range.isEmpty { return AsyncThrowingStream { $0.finish() } }
    }
    for attempt in 0..<2 {
      let directURL = try await downloadURL(for: node.backing)
      do {
        let body = try await session.streamDownload(directURL, range: range)
        guard connected, generation == operation else { throw CancellationError() }
        return body
      } catch let error
        as LanzouError
        where attempt == 0 && (error == .notFound || error == .http(401) || error == .http(403))
      {
        downloadURLs.removeValue(forKey: node.backing)
      }
    }
    throw LanzouError.invalidResponse
  }

  public func write(_ path: RemotePath, from localFile: URL) async throws {
    throw RemoteError.posix(EROFS)
  }

  public func makeDirectory(_ path: RemotePath) async throws {
    throw RemoteError.posix(EROFS)
  }

  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    throw RemoteError.posix(EROFS)
  }

  public func move(_ from: RemotePath, to: RemotePath) async throws {
    throw RemoteError.posix(EROFS)
  }

  private func resolve(_ path: RemotePath) async throws -> Node {
    if path.value == "/" { return rootNode() }
    if let cached = nodes[path.value] { return cached }

    var currentPath = try RemotePath("/")
    var current = rootNode()
    for component in path.value.split(separator: "/").map(String.init) {
      let nextPath = try currentPath.appending(component)
      let children = try await directoryContents(current)
      let matches = children.filter { $0.item.name == component }
      guard matches.count <= 1 else { throw RemoteError.posix(EEXIST) }
      guard let child = matches.first else { throw RemoteError.posix(ENOENT) }
      currentPath = nextPath
      current = child
    }
    return current
  }

  private func directoryContents(_ node: Node) async throws -> [Node] {
    guard node.item.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    let operation = generation
    let request = UUID()
    directoryLoads[node.item.path.value] = request
    let children: [Node]
    switch node.backing {
    case .accountFolder(let folderID):
      let entries = try await session.accountChildren(folderID: folderID)
      children = try await nodes(for: entries, at: node.item.path) { entry in
        entry.isDirectory ? .accountFolder(entry.id) : .accountFile(entry.id)
      }
    case .accountFile:
      throw RemoteError.posix(ENOTDIR)
    case .sharePage(let url):
      let listing = try await session.shareListing(
        url: url, password: sharePassword)
      var childrenAndBacking: [(LanzouEntry, Backing)] = []
      for folder in listing.folders {
        childrenAndBacking.append(
          (
            LanzouEntry(
              name: folder.name, isDirectory: true, size: 0,
              modified: Date(timeIntervalSince1970: 0), id: ""),
            .sharePage(folder.url)
          ))
      }
      for file in listing.files {
        let fileURL: URL
        if listing.page.isFile {
          fileURL = listing.page.url
        } else {
          fileURL = try shareURL(id: file.id, relativeTo: listing.page.url)
        }
        childrenAndBacking.append((file, .sharePage(fileURL)))
      }
      children = try await nodes(for: childrenAndBacking, at: node.item.path)
    }
    guard connected, generation == operation, directoryLoads[node.item.path.value] == request else {
      throw CancellationError()
    }
    let prefix = node.item.path.value == "/" ? "/" : node.item.path.value + "/"
    let previous = nodes.filter { $0.key.hasPrefix(prefix) }
    nodes = nodes.filter { !$0.key.hasPrefix(prefix) }
    for old in previous.values {
      if !children.contains(where: {
        $0.backing == old.backing && $0.item.size == old.item.size
          && $0.item.modified == old.item.modified
      }) {
        downloadURLs.removeValue(forKey: old.backing)
        downloadTasks.removeValue(forKey: old.backing)?.cancel()
      }
    }
    let grouped = Dictionary(grouping: children, by: { $0.item.name })
    for child in children where grouped[child.item.name]?.count == 1 {
      nodes[child.item.path.value] = child
    }
    return children
  }

  private func nodes(
    for entries: [LanzouEntry], at parent: RemotePath, backing: (LanzouEntry) -> Backing
  ) async throws -> [Node] {
    try await nodes(for: entries.map { ($0, backing($0)) }, at: parent)
  }

  private func nodes(
    for entries: [(LanzouEntry, Backing)], at parent: RemotePath
  ) async throws -> [Node] {
    var result: [Node] = []
    for (entry, backing) in entries {
      try Task.checkCancellation()
      let path = try parent.appending(entry.name)
      let size: Int64
      if let exact = entry.size {
        size = exact
      } else {
        let url = try await downloadURL(for: backing)
        size = try await session.downloadSize(url)
      }
      result.append(
        Node(
          item: RemoteItem(
            path: path, name: entry.name, isDirectory: entry.isDirectory,
            size: size, modified: entry.modified), backing: backing))
    }
    return result
  }

  private func downloadURL(for backing: Backing) async throws -> URL {
    try requireConnection()
    if let cached = downloadURLs[backing] { return cached }
    if let pending = downloadTasks[backing] {
      let operation = generation
      let url = try await pending.value
      guard connected, generation == operation, !pending.isCancelled else {
        throw CancellationError()
      }
      return url
    }
    let operation = generation
    let task = Task { try await resolveDownloadURL(for: backing) }
    downloadTasks[backing] = task
    defer { if generation == operation { downloadTasks.removeValue(forKey: backing) } }
    let url = try await task.value
    guard connected, generation == operation, !task.isCancelled else { throw CancellationError() }
    downloadURLs[backing] = url
    return url
  }

  private func resolveDownloadURL(for backing: Backing) async throws -> URL {
    switch backing {
    case .accountFile(let fileID):
      let (shareURL, password) = try await session.accountDownloadLocation(fileID: fileID)
      return try await session.shareDownloadURL(url: shareURL, password: password)
    case .sharePage(let pageURL):
      return try await session.shareDownloadURL(url: pageURL, password: sharePassword)
    case .accountFolder:
      throw RemoteError.posix(EISDIR)
    }
  }

  private var sharePassword: String? {
    guard case .share(_, let password) = configuration.authentication else { return nil }
    return password
  }

  private func rootNode() -> Node {
    let path = try! RemotePath("/")
    let backing: Backing
    switch configuration.authentication {
    case .accountCookie:
      backing = .accountFolder("-1")
    case .share(let url, _):
      backing = .sharePage(url)
    }
    return Node(
      item: RemoteItem(
        path: path, name: "/", isDirectory: true, size: 0,
        modified: Date(timeIntervalSince1970: 0)),
      backing: backing)
  }

  private func shareURL(id: String, relativeTo pageURL: URL) throws -> URL {
    guard !id.isEmpty,
      id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
      var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)
    else { throw LanzouError.invalidResponse }
    components.path = "/" + id
    components.query = nil
    components.fragment = nil
    guard let url = components.url else { throw LanzouError.invalidResponse }
    return url
  }

  private func requireConnection() throws {
    guard connected else { throw RemoteError.notConnected }
  }
}
