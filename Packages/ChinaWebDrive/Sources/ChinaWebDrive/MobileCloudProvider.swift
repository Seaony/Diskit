import Core
import Foundation

private struct MobileCloudItem: Decodable, Equatable, Sendable {
  let fileID: String
  let name: String
  let parentFileID: String?
  let size: FlexibleInt64?
  let type: String
  let createdAt: FlexibleString?
  let updatedAt: FlexibleString?

  enum CodingKeys: String, CodingKey {
    case name, size, type
    case fileID = "fileId"
    case parentFileID = "parentFileId"
    case createdAt, updatedAt
  }

  var isDirectory: Bool { type.lowercased() == "folder" }

  func item(at path: RemotePath) throws -> RemoteItem {
    guard ChinaWebSupport.isValidRemoteName(name), !fileID.isEmpty,
      ["file", "folder"].contains(type.lowercased())
    else {
      throw MobileCloudError.invalidResponse
    }
    let value = size?.value ?? 0
    guard value >= 0 else { throw MobileCloudError.invalidResponse }
    return RemoteItem(
      path: path, name: name, isDirectory: isDirectory,
      size: isDirectory ? 0 : value,
      modified: ChinaWebSupport.parseDate(updatedAt?.value ?? createdAt?.value))
  }
}

private struct MobileCloudPage: Decodable {
  let items: [MobileCloudItem]
  let nextPageCursor: String?
}

private struct MobileCloudDiskInfo: Decodable {
  let diskSize: FlexibleInt64?
  let freeDiskSize: FlexibleInt64?
  let totalSize: FlexibleInt64?
  let usedSize: FlexibleInt64?
}

private struct MobileCloudCreate: Decodable {
  struct Part: Decodable {
    let partNumber: Int
    let partSize: Int64
    let uploadURL: URL
    enum CodingKeys: String, CodingKey {
      case partNumber, partSize
      case uploadURL = "uploadUrl"
    }
  }
  let fileID: String
  let fileName: String
  let uploadID: String?
  let rapidUpload: Bool?
  let exist: Bool?
  let partInfos: [Part]?
  enum CodingKeys: String, CodingKey {
    case fileName, rapidUpload, exist, partInfos
    case fileID = "fileId"
    case uploadID = "uploadId"
  }
}

private struct MobileCloudUploadURLs: Decodable {
  let partInfos: [MobileCloudCreate.Part]
}

private struct MobileCloudDownload: Decodable {
  let url: URL
}

private struct MobileCloudUploadPart: Sendable, Equatable {
  let number: Int
  let offset: Int64
  let length: Int64

  static func split(size: Int64, partSize: Int64) throws -> [MobileCloudUploadPart] {
    guard size >= 0, partSize > 0 else { throw RemoteError.protocolError }
    if size == 0 { return [MobileCloudUploadPart(number: 1, offset: 0, length: 0)] }
    var output: [MobileCloudUploadPart] = []
    var offset: Int64 = 0
    while offset < size {
      guard output.count < 10_000 else { throw RemoteError.posix(EFBIG) }
      let length = min(partSize, size - offset)
      output.append(
        MobileCloudUploadPart(number: output.count + 1, offset: offset, length: length))
      offset += length
    }
    return output
  }
}

public actor MobileCloudProvider: RemoteFileProvider {
  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)

  private let session: MobileCloudSession
  private let partSize: Int64
  private let maxPartsPerURL: Int
  private var connected = false
  private var nodes: [String: MobileCloudItem] = [:]
  private var cacheGeneration = 0
  private var listingIDs: [String: UUID] = [:]
  private var progress: (@Sendable (Int64, Int64) -> Void)?

  public init(
    session: MobileCloudSession, partSize: Int64 = 20 * 1024 * 1024,
    maxPartsPerURL: Int = 100
  ) {
    self.session = session
    self.partSize = partSize
    self.maxPartsPerURL = min(max(maxPartsPerURL, 1), 100)
  }

  public func onProgress(_ progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.progress = progress
  }

  public func connect() async throws {
    try await session.connect()
    connected = true
    cacheGeneration += 1
    listingIDs.removeAll()
    nodes.removeAll()
  }

  public func disconnect() async {
    connected = false
    cacheGeneration += 1
    listingIDs.removeAll()
    nodes.removeAll()
  }

  public func spaceInfo() async throws -> SpaceInfo {
    try requireConnection()
    let data = try await session.accountRequest(
      "disk/getPersonalDiskInfo", body: ["userDomainId": await session.userDomainID ?? ""])
    let info: MobileCloudDiskInfo = try decode(data)
    let total = (info.diskSize ?? info.totalSize)?.value
    let free = info.freeDiskSize?.value
    let used = info.usedSize?.value
    guard [total, free, used].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
      throw MobileCloudError.invalidResponse
    }
    if let total, let free {
      guard total >= 0, free >= 0, free <= total else {
        throw MobileCloudError.invalidResponse
      }
      return SpaceInfo(total: total, used: total - free)
    }
    return SpaceInfo(total: total, used: used, available: free)
  }

  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    let folder = try await resolve(path)
    guard folder.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    return try await children(path, parentID: folder.fileID).map {
      try $0.item(at: path.appending($0.name))
    }
  }

  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    try requireConnection()
    if path.value == "/" { return rootItem(path) }
    return try await resolve(path).item(at: path)
  }

  public func read(
    _ path: RemotePath, range: Range<Int64>?
  ) async throws -> AsyncThrowingStream<Data, Error> {
    let node = try await resolve(path)
    let metadata = try node.item(at: path)
    guard !metadata.isDirectory else { throw RemoteError.posix(EISDIR) }
    let requested: Range<Int64>?
    if let range {
      guard range.lowerBound >= 0, range.upperBound >= range.lowerBound,
        range.lowerBound <= metadata.size
      else { throw RemoteError.posix(EINVAL) }
      requested = range.lowerBound..<min(range.upperBound, metadata.size)
    } else {
      requested = nil
    }
    if metadata.size == 0 || requested?.isEmpty == true {
      return AsyncThrowingStream { $0.finish() }
    }
    for attempt in 0..<2 {
      let data = try await session.request("file/getDownloadUrl", body: ["fileId": node.fileID])
      let reply: MobileCloudDownload = try decode(data)
      let stream = try await session.unsignedDownload(reply.url, range: requested)
      if [401, 403].contains(stream.response.status), attempt == 0 { continue }
      try ChinaWebSupport.checkHTTP(stream.response)
      if let requested {
        guard stream.response.status == 206,
          ChinaWebSupport.validRange(
            stream.response.header("Content-Range"), requested: requested,
            size: metadata.size)
        else { throw RemoteError.protocolError }
      } else {
        guard stream.response.status == 200 else { throw RemoteError.protocolError }
      }
      return stream.body
    }
    throw RemoteError.posix(EACCES)
  }

  public func write(_ path: RemotePath, from localFile: URL) async throws {
    let progress = self.progress
    guard path.value != "/" else { throw RemoteError.posix(EISDIR) }
    let destination = ChinaWebSupport.parent(of: path)
    let folder = try await resolve(destination)
    guard folder.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    let name = ChinaWebSupport.basename(path)
    let existing = try await children(destination, parentID: folder.fileID)
    guard !existing.contains(where: { $0.name == name }) else {
      throw RemoteError.posix(EEXIST)
    }
    let attributes = try localFile.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard attributes.isRegularFile == true, let size = attributes.fileSize, size >= 0 else {
      throw RemoteError.posix(EIO)
    }
    let parts = try MobileCloudUploadPart.split(size: Int64(size), partSize: partSize)
    let hashAlgorithm = await session.hashAlgorithm
    let contentHash = try ChinaWebSupport.fileDigest(localFile, algorithm: hashAlgorithm)
    let firstParts = Array(parts.prefix(maxPartsPerURL))
    let createBody: [String: Any] = [
      "parentFileId": folder.fileID,
      "name": name,
      "type": "file",
      "size": Int64(size),
      "fileRenameMode": "auto_rename",
      "contentHash": contentHash,
      "contentHashAlgorithm": hashAlgorithm,
      "contentType": "application/octet-stream",
      "parallelUpload": false,
      "partInfos": firstParts.map {
        [
          "partNumber": $0.number, "partSize": $0.length,
          "parallelHashCtx": ["partOffset": $0.offset],
        ]
      },
    ]
    defer { invalidate(destination) }
    let createdData = try await session.request("file/create", body: createBody)
    let created: MobileCloudCreate = try decode(createdData)
    guard !created.fileID.isEmpty else { throw MobileCloudError.invalidResponse }
    guard created.exist != true, !existing.contains(where: { $0.fileID == created.fileID }) else {
      throw RemoteError.posix(EEXIST)
    }
    do {
      guard created.fileName == name else {
        throw RemoteError.posix(EEXIST)
      }
      if created.rapidUpload == true {
        progress?(Int64(size), Int64(size))
        return
      }
      guard let uploadID = created.uploadID, !uploadID.isEmpty else {
        throw MobileCloudError.invalidResponse
      }
      let handle = try FileHandle(forReadingFrom: localFile)
      defer { try? handle.close() }
      for offset in stride(from: 0, to: parts.count, by: maxPartsPerURL) {
        let batch = Array(parts[offset..<min(offset + maxPartsPerURL, parts.count)])
        let serverParts: [MobileCloudCreate.Part]
        if offset == 0 {
          guard let parts = created.partInfos else {
            throw MobileCloudError.invalidResponse
          }
          serverParts = parts
        } else {
          let data = try await session.request(
            "file/getUploadUrl",
            body: [
              "fileId": created.fileID, "uploadId": uploadID,
              "partInfos": batch.map {
                [
                  "partNumber": $0.number, "partSize": $0.length,
                  "parallelHashCtx": ["partOffset": $0.offset],
                ]
              },
            ])
          let reply: MobileCloudUploadURLs = try decode(data)
          serverParts = reply.partInfos
        }
        let sortedParts = serverParts.sorted { $0.partNumber < $1.partNumber }
        guard sortedParts.count == batch.count,
          sortedParts.map(\.partNumber) == batch.map(\.number)
        else { throw MobileCloudError.invalidResponse }
        for (part, serverPart) in zip(batch, sortedParts) {
          try Task.checkCancellation()
          guard serverPart.partSize == part.length,
            serverPart.uploadURL.scheme == "https", serverPart.uploadURL.user == nil,
            serverPart.uploadURL.password == nil
          else { throw MobileCloudError.invalidResponse }
          try handle.seek(toOffset: UInt64(part.offset))
          var payload = Data()
          while payload.count < part.length {
            guard let block = try handle.read(upToCount: Int(part.length) - payload.count),
              !block.isEmpty
            else { throw RemoteError.posix(EIO) }
            payload.append(block)
          }
          var request = URLRequest(
            url: serverPart.uploadURL, timeoutInterval: RemoteTimeout.transferIdle)
          request.httpMethod = "PUT"
          request.httpBody = payload
          request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
          request.setValue(ChinaWebSupport.userAgent, forHTTPHeaderField: "User-Agent")
          let response = try await session.unsignedUpload(request)
          try ChinaWebSupport.checkHTTP(response)
          progress?(part.offset + part.length, Int64(size))
        }
      }
      let _ = try await session.request(
        "file/complete",
        body: [
          "fileId": created.fileID, "uploadId": uploadID, "contentHash": contentHash,
          "contentHashAlgorithm": hashAlgorithm,
        ])
    } catch {
      await discard(created.fileID)
      throw error
    }
  }

  public func makeDirectory(_ path: RemotePath) async throws {
    guard path.value != "/" else {
      try requireConnection()
      return
    }
    let destination = ChinaWebSupport.parent(of: path)
    let folder = try await resolve(destination)
    guard folder.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    let existing = try await children(destination, parentID: folder.fileID)
    guard !existing.contains(where: { $0.name == ChinaWebSupport.basename(path) }) else {
      throw RemoteError.posix(EEXIST)
    }
    let body: [String: Any] = [
      "parentFileId": folder.fileID,
      "name": ChinaWebSupport.basename(path),
      "description": "",
      "type": "folder",
      "fileRenameMode": "auto_rename",
    ]
    defer { invalidate(destination) }
    let data = try await session.request("file/create", body: body)
    let created: MobileCloudCreate = try decode(data)
    guard !created.fileID.isEmpty else { throw MobileCloudError.invalidResponse }
    guard created.exist != true, !existing.contains(where: { $0.fileID == created.fileID }) else {
      throw RemoteError.posix(EEXIST)
    }
    guard created.fileName == ChinaWebSupport.basename(path) else {
      await discard(created.fileID)
      throw RemoteError.posix(EEXIST)
    }
  }

  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    guard path.value != "/" else { throw RemoteError.posix(EACCES) }
    let node = try await resolve(path)
    if node.isDirectory, !recursive, !(try await children(path, parentID: node.fileID)).isEmpty {
      throw RemoteError.posix(ENOTEMPTY)
    }
    defer { invalidate(ChinaWebSupport.parent(of: path)) }
    let _ = try await session.request(
      "recyclebin/batchTrash", body: ["fileIds": [node.fileID]])
  }

  public func move(_ from: RemotePath, to: RemotePath) async throws {
    guard from.value != "/", to.value != "/" else { throw RemoteError.posix(EACCES) }
    if from == to { return }
    let node = try await resolve(from)
    let source = ChinaWebSupport.parent(of: from)
    let destination = ChinaWebSupport.parent(of: to)
    if node.isDirectory, to.value.hasPrefix(from.value + "/") { throw RemoteError.posix(EINVAL) }
    let sourceFolder = try await resolve(source)
    let folder = try await resolve(destination)
    guard folder.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    let targetName = ChinaWebSupport.basename(to)
    let conflicts = try await children(destination, parentID: folder.fileID).filter {
      $0.name == targetName && $0.fileID != node.fileID
    }
    guard conflicts.isEmpty else { throw RemoteError.posix(EEXIST) }
    defer {
      invalidate(source)
      invalidate(destination)
    }
    let needsTemporaryName = source != destination && node.name != targetName
    var lastConfirmed = from
    do {
      if needsTemporaryName {
        let temporary = ".diskit-move-" + UUID().uuidString
        try await rename(node.fileID, to: temporary)
        lastConfirmed = try source.appending(temporary)
      }
      if source != destination {
        _ = try await session.request(
          "file/batchMove", body: ["fileIds": [node.fileID], "toParentFileId": folder.fileID])
        lastConfirmed = try destination.appending(ChinaWebSupport.basename(lastConfirmed))
      }
      if ChinaWebSupport.basename(lastConfirmed) != targetName {
        try await rename(node.fileID, to: targetName)
        lastConfirmed = to
      }
    } catch {
      let original = error
      guard needsTemporaryName else { throw original }
      do {
        let sourceItems = try await children(source, parentID: sourceFolder.fileID)
        let current: MobileCloudItem
        if let found = sourceItems.first(where: { $0.fileID == node.fileID }) {
          current = found
          lastConfirmed = try source.appending(found.name)
        } else {
          let destinationItems = try await children(destination, parentID: folder.fileID)
          guard let found = destinationItems.first(where: { $0.fileID == node.fileID }) else {
            throw RemoteError.posix(ENOENT)
          }
          current = found
          lastConfirmed = try destination.appending(found.name)
          guard !sourceItems.contains(where: { $0.name == found.name && $0.fileID != node.fileID })
          else {
            throw RemoteError.posix(EEXIST)
          }
          _ = try await session.request(
            "file/batchMove",
            body: ["fileIds": [node.fileID], "toParentFileId": sourceFolder.fileID])
          lastConfirmed = try source.appending(found.name)
        }
        if current.name != node.name {
          guard !sourceItems.contains(where: { $0.name == node.name && $0.fileID != node.fileID })
          else {
            throw RemoteError.posix(EEXIST)
          }
          try await rename(node.fileID, to: node.name)
          lastConfirmed = from
        }
      } catch {
        throw MobileCloudMoveFailure(
          lastConfirmedPath: lastConfirmed.value, original: original, recovery: error)
      }
      throw original
    }
  }

  private func rename(_ id: String, to name: String) async throws {
    _ = try await session.request(
      "file/update", body: ["fileId": id, "name": name, "description": ""])
  }

  private func requireConnection() throws {
    guard connected else { throw RemoteError.notConnected }
  }

  private func discard(_ fileID: String) async {
    let session = session
    let cleanup = Task.detached {
      _ = try? await session.request("recyclebin/batchTrash", body: ["fileIds": [fileID]])
    }
    await cleanup.value
  }

  private func root() -> MobileCloudItem {
    MobileCloudItem(
      fileID: "/", name: "/", parentFileID: nil, size: nil, type: "folder", createdAt: nil,
      updatedAt: nil)
  }

  private func rootItem(_ path: RemotePath) -> RemoteItem {
    RemoteItem(
      path: path, name: "/", isDirectory: true, size: 0,
      modified: Date(timeIntervalSince1970: 0))
  }

  private func resolve(_ path: RemotePath) async throws -> MobileCloudItem {
    try requireConnection()
    if path.value == "/" { return root() }
    if let cached = nodes[path.value] { return cached }
    var currentPath = try RemotePath("/")
    var current = root()
    for component in path.value.split(separator: "/").map(String.init) {
      guard current.isDirectory else { throw RemoteError.posix(ENOTDIR) }
      let nextPath = try currentPath.appending(component)
      if let cached = nodes[nextPath.value] {
        current = cached
        currentPath = nextPath
        continue
      }
      let matches = try await children(currentPath, parentID: current.fileID).filter {
        $0.name == component
      }
      guard matches.count <= 1 else { throw RemoteError.posix(EEXIST) }
      guard let match = matches.first else { throw RemoteError.posix(ENOENT) }
      current = match
      currentPath = nextPath
    }
    return current
  }

  private func children(_ path: RemotePath, parentID: String) async throws -> [MobileCloudItem] {
    let generation = cacheGeneration
    let listingID = UUID()
    listingIDs[path.value] = listingID
    clearCachedChildren(path)
    defer {
      if listingIDs[path.value] == listingID { listingIDs.removeValue(forKey: path.value) }
    }
    var cursor = ""
    var byID: [String: MobileCloudItem] = [:]
    var visited = Set<String>()
    var output: [MobileCloudItem] = []
    repeat {
      try Task.checkCancellation()
      let body: [String: Any] = [
        "imageThumbnailStyleList": ["Small", "Large"],
        "orderBy": "updated_at",
        "orderDirection": "DESC",
        "pageInfo": ["pageSize": 100, "pageCursor": cursor],
        "parentFileId": parentID,
      ]
      let data = try await session.request("file/list", body: body)
      let page: MobileCloudPage = try decode(data)
      for item in page.items {
        let child = try path.appending(item.name)
        _ = try item.item(at: child)
        if let previous = byID[item.fileID] {
          guard previous == item else { throw MobileCloudError.invalidResponse }
          continue
        }
        byID[item.fileID] = item
        output.append(item)
      }
      cursor = page.nextPageCursor ?? ""
      if !cursor.isEmpty, !visited.insert(cursor).inserted {
        throw MobileCloudError.invalidResponse
      }
    } while !cursor.isEmpty
    guard generation == cacheGeneration, listingIDs[path.value] == listingID else {
      throw RemoteError.posix(EAGAIN)
    }
    clearCachedChildren(path)
    let grouped = Dictionary(grouping: output, by: \.name)
    for item in output {
      let child = try path.appending(item.name)
      _ = try item.item(at: child)
      if grouped[item.name]?.count == 1 { nodes[child.value] = item }
    }
    return output
  }

  private func decode<T: Decodable>(_ data: Data) throws -> T {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      root["success"] as? Bool != false,
      let value = root["data"], !(value is NSNull)
    else { throw MobileCloudError.invalidResponse }
    do {
      return try JSONDecoder().decode(
        T.self, from: JSONSerialization.data(withJSONObject: value))
    } catch {
      throw MobileCloudError.invalidResponse
    }
  }

  private func invalidate(_ path: RemotePath) {
    cacheGeneration += 1
    clearCachedChildren(path)
  }

  private func clearCachedChildren(_ path: RemotePath) {
    let prefix = path.value == "/" ? "/" : path.value + "/"
    for key in Array(nodes.keys) where key.hasPrefix(prefix) {
      nodes.removeValue(forKey: key)
    }
  }

  static func splitForTesting(size: Int64, partSize: Int64) throws -> [(Int, Int64, Int64)] {
    try MobileCloudUploadPart.split(size: size, partSize: partSize).map {
      ($0.number, $0.offset, $0.length)
    }
  }
}
