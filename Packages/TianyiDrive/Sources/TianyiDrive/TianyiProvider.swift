import Core
import CryptoKit
import Foundation

public actor TianyiProvider: RemoteFileProvider {
  public nonisolated let capabilities = ProviderCapabilities(
    canWrite: true, canRename: true, canMove: true, canDelete: true, supportsRangeRead: true)

  private let session: TianyiSession
  private let uploadSliceSize: Int64?
  private let taskPollInterval: Duration
  private var connected = false
  private var paths: [String: TianyiNode] = [:]
  private var progress: (@Sendable (Int64, Int64) -> Void)?

  public init(
    session: TianyiSession, uploadSliceSize: Int64? = nil,
    taskPollInterval: Duration = .milliseconds(400)
  ) {
    self.session = session
    self.uploadSliceSize = uploadSliceSize
    self.taskPollInterval = taskPollInterval
  }

  public func onProgress(_ progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.progress = progress
  }

  public func connect() async throws {
    try await session.connect()
    connected = true
    paths.removeAll()
  }

  public func disconnect() async {
    connected = false
    paths.removeAll()
  }

  public func spaceInfo() async throws -> SpaceInfo {
    try requireConnection()
    let account = try await session.account()
    return SpaceInfo(total: account.total, used: account.used)
  }

  public func list(_ path: RemotePath) async throws -> [RemoteItem] {
    let folder = try await resolve(path)
    guard folder.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    return try await children(path, folderID: folder.id).map {
      try $0.item(at: path.appending($0.name))
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  public func stat(_ path: RemotePath) async throws -> RemoteItem {
    try requireConnection()
    if path.value == "/" { return rootItem(path) }
    return try await resolve(path).item(at: path)
  }

  public func read(
    _ path: RemotePath, range: Range<Int64>?
  ) async throws -> AsyncThrowingStream<Data, Error> {
    let item = try await stat(path)
    guard !item.isDirectory else { throw RemoteError.posix(EISDIR) }
    if item.size == 0 {
      guard range == nil || range?.isEmpty == true else {
        throw RemoteError.posix(EINVAL)
      }
      return AsyncThrowingStream { $0.finish() }
    }
    let requested: Range<Int64>?
    if let range {
      guard range.lowerBound >= 0, range.lowerBound <= item.size,
        range.upperBound >= range.lowerBound
      else { throw RemoteError.posix(EINVAL) }
      let clamped = range.lowerBound..<min(range.upperBound, item.size)
      if clamped.isEmpty { return AsyncThrowingStream { $0.finish() } }
      requested = clamped
    } else {
      requested = nil
    }
    let file = try await resolve(path)
    let response = try await session.api(
      path: scope.isFamily
        ? "/family/file/getFileDownloadUrl.action" : "/file/getFileDownloadUrl.action",
      method: "GET", query: try downloadQuery(fileID: file.id))
    guard let object = TianyiJSON.object(from: response.body),
      let raw = object["fileDownloadUrl"] as? String,
      var components = URLComponents(
        string: raw.replacingOccurrences(of: "&amp;", with: "&"))
    else { throw TianyiError.invalidResponse }
    components.scheme = components.scheme?.replacingOccurrences(of: "http", with: "https")
    guard components.scheme == "https", let url = components.url else {
      throw TianyiError.invalidResponse
    }
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.httpMethod = "GET"
    if let requested {
      request.setValue(
        "bytes=\(requested.lowerBound)-\(requested.upperBound - 1)",
        forHTTPHeaderField: "Range")
    }
    let stream = try await session.stream(request)
    if let requested {
      guard stream.response.status == 206,
        Self.validContentRange(
          stream.response.header("Content-Range"), requested: requested, size: item.size)
      else { throw RemoteError.protocolError }
    } else {
      guard stream.response.status == 200 else {
        throw TianyiHTTP.map(status: stream.response.status, body: stream.response.body)
      }
    }
    return stream.body
  }

  public func write(_ path: RemotePath, from localFile: URL) async throws {
    guard path.value != "/" else { throw RemoteError.posix(EISDIR) }
    let destination = parent(of: path)
    let folder = try await resolve(destination)
    guard folder.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    let name = basename(path)
    guard try await children(destination, folderID: folder.id).allSatisfy({ $0.name != name })
    else { throw RemoteError.posix(EEXIST) }
    let attributes = try localFile.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard attributes.isRegularFile == true, let fileSize = attributes.fileSize, fileSize >= 0 else {
      throw RemoteError.posix(EIO)
    }
    let size = Int64(fileSize)
    let plan = try TianyiUploadPlan.make(
      from: localFile, size: size, requestedSliceSize: uploadSliceSize)
    let encodedName = Self.percentEncode(name)
    let uploadPrefix = scope.isFamily ? "/family" : "/person"
    var initParams = [
      "parentFolderId": folder.id,
      "fileName": encodedName,
      "fileSize": String(size),
      "sliceSize": String(plan.sliceSize),
      "fileMd5": plan.fileMD5,
      "sliceMd5": plan.sliceMD5,
    ]
    if scope.isFamily {
      initParams["familyId"] = try configuredFamilyID()
    }
    let initialized = try await session.upload(
      path: uploadPrefix + "/initMultiUpload", params: initParams)
    guard let initObject = TianyiJSON.object(from: initialized.body),
      let data = initObject["data"] as? [String: Any],
      let uploadFileID = Self.string(data["uploadFileId"]), !uploadFileID.isEmpty
    else { throw TianyiError.invalidResponse }
    let alreadyStored = Self.integer(data["fileDataExists"]) == 1
    if !alreadyStored {
      for part in plan.parts {
        try Task.checkCancellation()
        let urlsResponse = try await session.upload(
          path: uploadPrefix + "/getMultiUploadUrls",
          params: ["uploadFileId": uploadFileID, "partInfo": part.info])
        guard
          let urlInfo = try uploadURL(
            response: urlsResponse, partNumber: part.number)
        else { throw TianyiError.invalidResponse }
        let bytes = try plan.data(for: part, in: localFile)
        _ = try await session.uploadChunk(
          url: urlInfo.url, headers: urlInfo.headers, body: bytes)
        progress?(part.offset + part.length, size)
      }
    } else {
      progress?(size, size)
    }
    _ = try await session.upload(
      path: uploadPrefix + "/commitMultiUploadFile",
      params: ["uploadFileId": uploadFileID, "isLog": "0", "opertype": "1"])
    invalidate(destination)
  }

  public func makeDirectory(_ path: RemotePath) async throws {
    guard path.value != "/" else {
      try requireConnection()
      return
    }
    let destination = parent(of: path)
    let folder = try await resolve(destination)
    guard folder.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    let name = basename(path)
    guard try await children(destination, folderID: folder.id).allSatisfy({ $0.name != name })
    else { throw RemoteError.posix(EEXIST) }
    let pathValue =
      scope.isFamily ? "/family/file/createFolder.action" : "/file/createFolder.action"
    var query = [
      URLQueryItem(name: "folderName", value: name),
      URLQueryItem(name: "relativePath", value: ""),
    ]
    if scope.isFamily {
      query += [
        URLQueryItem(name: "familyId", value: try configuredFamilyID()),
        URLQueryItem(name: "parentId", value: folder.id),
      ]
    } else {
      query.append(URLQueryItem(name: "parentFolderId", value: folder.id))
    }
    _ = try await session.api(path: pathValue, method: "POST", query: query)
    invalidate(destination)
  }

  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    guard path.value != "/" else { throw RemoteError.posix(EACCES) }
    let node = try await resolve(path)
    if node.isDirectory, !recursive, !(try await children(path, folderID: node.id)).isEmpty {
      throw RemoteError.posix(ENOTEMPTY)
    }
    try await batchTask(
      path: "/batch/createBatchTask.action", type: "DELETE", targetFolderID: "",
      node: node)
    invalidate(parent(of: path))
  }

  public func move(_ from: RemotePath, to: RemotePath) async throws {
    guard from.value != "/", to.value != "/" else {
      throw RemoteError.posix(EACCES)
    }
    if from == to { return }
    let node = try await resolve(from)
    let sourceParent = parent(of: from)
    let destinationParent = parent(of: to)
    let destination = try await resolve(destinationParent)
    guard destination.isDirectory else { throw RemoteError.posix(ENOTDIR) }
    guard
      try await children(destinationParent, folderID: destination.id).allSatisfy({
        $0.name != basename(to)
      })
    else { throw RemoteError.posix(EEXIST) }

    do {
      if sourceParent != destinationParent {
        try await batchTask(
          path: "/batch/createBatchTask.action", type: "MOVE",
          targetFolderID: destination.id, node: node)
      }
      if basename(from) != basename(to) {
        let method = scope.isFamily ? "GET" : "POST"
        let prefix = scope.isFamily ? "/family/file" : "/file"
        var query: [URLQueryItem]
        if node.isDirectory {
          query = [
            URLQueryItem(name: "folderId", value: node.id),
            URLQueryItem(name: "destFolderName", value: basename(to)),
          ]
          if scope.isFamily {
            query.append(URLQueryItem(name: "familyId", value: try configuredFamilyID()))
          }
          _ = try await session.api(
            path: prefix + "/renameFolder.action", method: method, query: query)
        } else {
          query = [
            URLQueryItem(name: "fileId", value: node.id),
            URLQueryItem(name: "destFileName", value: basename(to)),
          ]
          if scope.isFamily {
            query.append(URLQueryItem(name: "familyId", value: try configuredFamilyID()))
          }
          _ = try await session.api(
            path: prefix + "/renameFile.action", method: method, query: query)
        }
      }
    } catch {
      invalidate(sourceParent)
      invalidate(destinationParent)
      throw error
    }
    invalidate(sourceParent)
    invalidate(destinationParent)
  }

  private func requireConnection() throws {
    guard connected else { throw RemoteError.notConnected }
  }

  private func rootItem(_ path: RemotePath) -> RemoteItem {
    RemoteItem(
      path: path, name: "/", isDirectory: true, size: 0,
      modified: Date(timeIntervalSince1970: 0))
  }

  private func rootNode() -> TianyiNode {
    TianyiNode(
      id: scope.rootFolderID, name: "/", isDirectory: true, size: 0,
      modified: Date(timeIntervalSince1970: 0))
  }

  private func resolve(_ path: RemotePath) async throws -> TianyiNode {
    try requireConnection()
    if path.value == "/" { return rootNode() }
    if let cached = paths[path.value] { return cached }
    var current = try RemotePath("/")
    var node = rootNode()
    for name in path.value.split(separator: "/").map(String.init) {
      guard node.isDirectory else { throw RemoteError.posix(ENOTDIR) }
      let next = try current.appending(name)
      if let cached = paths[next.value] {
        node = cached
        current = next
        continue
      }
      let matches = try await children(current, folderID: node.id).filter { $0.name == name }
      guard matches.count <= 1 else { throw RemoteError.posix(EEXIST) }
      guard let match = matches.first else { throw RemoteError.posix(ENOENT) }
      node = match
      current = next
    }
    return node
  }

  private func children(_ path: RemotePath, folderID: String) async throws -> [TianyiNode] {
    var pageNumber = 1
    var nodes: [TianyiNode] = []
    while pageNumber <= 10_000 {
      try Task.checkCancellation()
      var query = [
        URLQueryItem(name: "folderId", value: folderID),
        URLQueryItem(name: "fileType", value: "0"),
        URLQueryItem(name: "mediaAttr", value: "0"),
        URLQueryItem(name: "iconOption", value: "5"),
        URLQueryItem(name: "pageNum", value: String(pageNumber)),
        URLQueryItem(name: "pageSize", value: String(session.configuration.pageSize)),
        URLQueryItem(
          name: "orderBy", value: scope.isFamily ? "1" : "filename"),
        URLQueryItem(name: "descending", value: "false"),
      ]
      if scope.isFamily {
        query.append(URLQueryItem(name: "familyId", value: try configuredFamilyID()))
      } else {
        query.append(URLQueryItem(name: "recursive", value: "0"))
      }
      let response = try await session.api(
        path: scope.isFamily ? "/family/file/listFiles.action" : "/file/listFiles.action",
        method: "GET", query: query)
      let list: TianyiFileList = try TianyiJSON.decode(TianyiFileList.self, from: response)
      guard let page = list.fileListAO else { throw TianyiError.invalidResponse }
      let pageNodes =
        (page.folderList ?? []).map(\.node) + (page.fileList ?? []).map(\.node)
      nodes.append(contentsOf: pageNodes)
      if pageNodes.count < session.configuration.pageSize { break }
      pageNumber += 1
    }
    guard pageNumber <= 10_000 else { throw TianyiError.invalidResponse }
    invalidate(path)
    let grouped = Dictionary(grouping: nodes, by: \.name)
    for node in nodes {
      let child = try path.appending(node.name)
      _ = node.item(at: child)
      if grouped[node.name]?.count == 1 { paths[child.value] = node }
    }
    return nodes
  }

  private func batchTask(
    path: String, type: String, targetFolderID: String, node: TianyiNode
  ) async throws {
    let taskInfo: [[String: Any]] = [
      [
        "fileId": node.id,
        "fileName": node.name,
        "isFolder": node.isDirectory ? 1 : 0,
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: taskInfo)
    guard let taskInfos = String(data: data, encoding: .utf8) else {
      throw TianyiError.invalidResponse
    }
    var form = ["type": type, "taskInfos": taskInfos]
    if !targetFolderID.isEmpty { form["targetFolderId"] = targetFolderID }
    if scope.isFamily {
      form["familyId"] = try configuredFamilyID()
    }
    let created = try await session.api(path: path, method: "POST", form: form)
    let task: TianyiTaskCreated = try TianyiJSON.decode(TianyiTaskCreated.self, from: created)
    guard let taskID = task.taskID, !taskID.isEmpty else {
      throw TianyiError.invalidResponse
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      let response = try await session.api(
        path: "/batch/checkBatchTask.action", method: "POST",
        form: ["type": type, "taskId": taskID], credentialKind: .personal)
      let status: TianyiTaskStatus = try TianyiJSON.decode(TianyiTaskStatus.self, from: response)
      switch status.taskStatus {
      case 4: return
      case 2: throw RemoteError.posix(EEXIST)
      case -1: throw TianyiError.invalidResponse
      default:
        if taskPollInterval > .zero {
          try await Task.sleep(for: taskPollInterval)
        }
      }
    }
    throw RemoteError.posix(ETIMEDOUT)
  }

  private func uploadURL(
    response: HTTPResponse, partNumber: Int
  ) throws -> (url: URL, headers: [String: String])? {
    guard let object = TianyiJSON.object(from: response.body) else {
      throw TianyiError.invalidResponse
    }
    let urls =
      object["uploadUrls"] as? [String: Any]
      ?? (object["data"] as? [String: Any])?["uploadUrls"] as? [String: Any]
    guard let value = urls?["partNumber_\(partNumber)"] as? [String: Any],
      let rawURL = value["requestURL"] as? String, let url = URL(string: rawURL),
      url.scheme?.lowercased() == "https"
    else { return nil }
    var headers: [String: String] = [:]
    if let raw = value["requestHeader"] as? String {
      for part in raw.split(separator: "&") {
        let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2 else { continue }
        headers[String(pair[0])] = String(pair[1])
      }
    }
    return (url, headers)
  }

  private func invalidate(_ directory: RemotePath) {
    let prefix = directory.value == "/" ? "/" : directory.value + "/"
    for key in Array(paths.keys) where key.hasPrefix(prefix) { paths.removeValue(forKey: key) }
  }

  private func parent(of path: RemotePath) -> RemotePath {
    try! RemotePath("/" + path.value.split(separator: "/").dropLast().joined(separator: "/"))
  }

  private func basename(_ path: RemotePath) -> String {
    path.value.split(separator: "/").last.map(String.init) ?? ""
  }

  private var scope: TianyiStorageScope {
    session.configuration.scope
  }

  private func configuredFamilyID() throws -> String {
    guard let value = scope.familyID?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { throw TianyiError.invalidFamilyID }
    return value
  }

  private func downloadQuery(fileID: String) throws -> [URLQueryItem] {
    var query = [URLQueryItem(name: "fileId", value: fileID)]
    if scope.isFamily {
      query.append(URLQueryItem(name: "familyId", value: try configuredFamilyID()))
    } else {
      query += [
        URLQueryItem(name: "dt", value: "3"),
        URLQueryItem(name: "flag", value: "1"),
      ]
    }
    return query
  }

  private static func percentEncode(_ value: String) -> String {
    value.addingPercentEncoding(
      withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()")))
      ?? value
  }

  private static func integer(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
  }

  private static func string(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
  }

  static func validContentRange(
    _ header: String?, requested: Range<Int64>, size: Int64
  ) -> Bool {
    guard let header, header.hasPrefix("bytes ") else { return false }
    let fields = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
    guard fields.count == 2, Int64(fields[1]) == size else { return false }
    let bounds = fields[0].split(separator: "-", omittingEmptySubsequences: false)
    return bounds.count == 2 && Int64(bounds[0]) == requested.lowerBound
      && Int64(bounds[1]) == requested.upperBound - 1
  }
}
