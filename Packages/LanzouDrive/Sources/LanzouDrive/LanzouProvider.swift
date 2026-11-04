import Core
import Foundation

public actor LanzouProvider: RemoteFileProvider {
  private enum Backing: Equatable, Sendable {
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

  public init(
    configuration: LanzouConfiguration,
    transport: any HTTPTransport = URLSessionHTTPTransport()
  ) {
    self.configuration = configuration
    session = LanzouSession(configuration: configuration, transport: transport)
  }

  public func connect() async throws {
    try await session.connect()
    connected = true
    nodes.removeAll()
  }

  public func disconnect() async {
    connected = false
    nodes.removeAll()
    await session.disconnect()
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
    let node = try await resolve(path)
    guard !node.item.isDirectory else { throw RemoteError.posix(EISDIR) }
    guard let range else {
      let directURL = try await downloadURL(for: node.backing)
      return try await session.streamDownload(
        directURL, range: nil)
    }
    guard range.lowerBound >= 0, range.upperBound >= range.lowerBound else {
      throw RemoteError.posix(EINVAL)
    }
    if range.isEmpty { return AsyncThrowingStream { $0.finish() } }
    let directURL = try await downloadURL(for: node.backing)
    return try await session.streamDownload(directURL, range: range)
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
      nodes[nextPath.value] = child
      currentPath = nextPath
      current = child
    }
    return current
  }

  private func directoryContents(_ node: Node) async throws -> [Node] {
    guard node.item.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    let children: [Node]
    switch node.backing {
    case .accountFolder(let folderID):
      let entries = try await session.accountChildren(folderID: folderID)
      children = try nodes(for: entries, at: node.item.path) { entry in
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
      children = try nodes(for: childrenAndBacking, at: node.item.path)
    }
    let grouped = Dictionary(grouping: children, by: { $0.item.name })
    for child in children where grouped[child.item.name]?.count == 1 {
      nodes[child.item.path.value] = child
    }
    return children
  }

  private func nodes(
    for entries: [LanzouEntry], at parent: RemotePath, backing: (LanzouEntry) -> Backing
  ) throws -> [Node] {
    try entries.map { entry in
      Node(
        item: RemoteItem(
          path: try parent.appending(entry.name), name: entry.name,
          isDirectory: entry.isDirectory, size: entry.size, modified: entry.modified),
        backing: backing(entry))
    }
  }

  private func nodes(
    for entries: [(LanzouEntry, Backing)], at parent: RemotePath
  ) throws -> [Node] {
    try entries.map { pair in
      let (entry, backing) = pair
      return Node(
        item: RemoteItem(
          path: try parent.appending(entry.name), name: entry.name,
          isDirectory: entry.isDirectory, size: entry.size, modified: entry.modified),
        backing: backing)
    }
  }

  private func downloadURL(for backing: Backing) async throws -> URL {
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
