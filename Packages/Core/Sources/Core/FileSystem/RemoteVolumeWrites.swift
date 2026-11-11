import Foundation

extension RemoteVolumeBackend {
  func temporaryWriteFile() throws -> URL {
    let directory = cacheRoot.appending(path: connectionID.uuidString).appending(path: "Writes")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: UUID().uuidString + ".data")
    guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    return file
  }

  func requireRewriteCapability() throws {
    guard capabilities.canWrite else { throw RemoteError.posix(EROFS) }
    guard replacesExisting || (capabilities.canDelete && capabilities.canRename) else {
      throw RemoteError.posix(EACCES)
    }
  }

  func prepareStage(_ path: RemotePath) async throws {
    guard capabilities.canWrite else { throw RemoteError.posix(EROFS) }
    if staged[path] != nil { return }
    let item = try await provider.stat(path)
    guard !item.isDirectory else { throw RemoteError.posix(EISDIR) }
    try requireRewriteCapability()
    let file = try temporaryWriteFile()
    do {
      let size = try await download(path, to: file)
      guard size == item.size else { throw RemoteError.protocolError }
      staged[path] = StagedFile(url: file, item: item, dirty: false, existedRemotely: true)
    } catch {
      try? FileManager.default.removeItem(at: file)
      throw error
    }
  }

  public func write(_ path: RemotePath, offset: Int64, data: Data) async throws -> Int {
    try await perform("write", path: path) { backend in
      try backend.requireConnection()
      guard offset >= 0, !offset.addingReportingOverflow(Int64(data.count)).overflow else {
        throw RemoteError.invalidPath
      }
      try await backend.prepareStage(path)
      guard var stage = backend.staged[path] else { throw RemoteError.posix(EIO) }
      let handle = try FileHandle(forWritingTo: stage.url)
      defer { try? handle.close() }
      try handle.seek(toOffset: UInt64(offset))
      try handle.write(contentsOf: data)
      stage.item.size = max(stage.item.size, offset + Int64(data.count))
      stage.item.modified = backend.now()
      stage.dirty = true
      backend.staged[path] = stage
      await backend.invalidate([path])
      return data.count
    }
  }

  public func resize(_ path: RemotePath, size: Int64) async throws {
    try await perform("resize", path: path) { backend in
      try backend.requireConnection()
      guard size >= 0 else { throw RemoteError.invalidPath }
      try await backend.prepareStage(path)
      guard var stage = backend.staged[path] else { throw RemoteError.posix(EIO) }
      let handle = try FileHandle(forWritingTo: stage.url)
      defer { try? handle.close() }
      try handle.truncate(atOffset: UInt64(size))
      stage.item.size = size
      stage.item.modified = backend.now()
      stage.dirty = true
      backend.staged[path] = stage
      await backend.invalidate([path])
    }
  }

  public func setModifiedDate(_ path: RemotePath, date: Date) async throws {
    try await perform("set-modified", path: path) { backend in
      try backend.requireConnection()
      try await backend.prepareStage(path)
      guard var stage = backend.staged[path] else { throw RemoteError.posix(EIO) }
      try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: stage.url.path)
      stage.item.modified = date
      stage.dirty = true
      backend.staged[path] = stage
      await backend.invalidate([path])
    }
  }

  public func flush(_ path: RemotePath) async throws {
    try await perform("flush", path: path) { try await $0.flushUnlocked(path) }
  }

  public func flushAll() async throws {
    try await perform("flush-all") { backend in
      for path in Array(backend.staged.keys) { try await backend.flushUnlocked(path) }
    }
  }

  func flushUnlocked(_ path: RemotePath) async throws {
    guard var stage = staged[path], stage.dirty else { return }
    try requireConnection()
    guard capabilities.canWrite else { throw RemoteError.posix(EROFS) }
    let exists = try await remoteItem(path) != nil
    // URL 会缓存文件属性；每次上传重新取 URL，避免沿用上次上传时的修改时间。
    let uploadFile = URL(fileURLWithPath: stage.url.path)
    do {
      if exists {
        guard stage.existedRemotely else { throw RemoteError.posix(EEXIST) }
        try requireRewriteCapability()
      }
      if exists && !replacesExisting {
        let temporary = try path.parent.appending(
          ".\(path.basename).kayoi-upload-\(UUID().uuidString)")
        hiddenUploads.insert(temporary)
        logger.info(
          "连接 \(self.connectionID.uuidString, privacy: .public) 开始替换，远端暂存 \(temporary.value, privacy: .public)"
        )
        do {
          try await provider.write(temporary, from: uploadFile)
          let uploaded = try await provider.stat(temporary)
          guard !uploaded.isDirectory, uploaded.size == stage.item.size else {
            throw RemoteError.protocolError
          }
          try await provider.remove(path, recursive: false)
          try await provider.move(temporary, to: path)
          hiddenUploads.remove(temporary)
        } catch {
          logger.error(
            "连接 \(self.connectionID.uuidString, privacy: .public) 替换未完成，远端暂存 \(temporary.value, privacy: .public)，本地暂存 \(stage.url.path, privacy: .public)"
          )
          throw error
        }
      } else {
        try await provider.write(path, from: uploadFile)
      }
      stage.dirty = false
      stage.existedRemotely = true
      staged[path] = stage
      await invalidate([path])
      logger.info(
        "连接 \(self.connectionID.uuidString, privacy: .public) 上传完成，字节数 \(stage.item.size)")
    } catch {
      await invalidate([path])
      logger.error(
        "连接 \(self.connectionID.uuidString, privacy: .public) 上传失败，本地内容保留于 \(stage.url.path, privacy: .public)"
      )
      throw error
    }
  }

  public func close(_ path: RemotePath) async throws {
    try await perform("close", path: path) { backend in
      try await backend.flushUnlocked(path)
      if let stage = backend.staged[path], !stage.retainedForRecovery {
        backend.staged.removeValue(forKey: path)
        do { try FileManager.default.removeItem(at: stage.url) } catch {
          backend.logger.error("上传已成功，本地暂存未清理：\(stage.url.path, privacy: .public)")
        }
      }
      backend.wholeFiles.removeValue(forKey: path)
    }
  }

  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    try await perform("remove", path: path) { backend in
      try backend.requireConnection()
      guard backend.capabilities.canDelete else { throw RemoteError.posix(EROFS) }
      if backend.staged[path]?.existedRemotely != false {
        try await backend.provider.remove(path, recursive: recursive)
      }
      for key in Array(backend.staged.keys) where Self.contains(path, key) {
        if let stage = backend.staged.removeValue(forKey: key) {
          try? FileManager.default.removeItem(at: stage.url)
        }
      }
      await backend.invalidate([path])
    }
  }

  public func move(_ from: RemotePath, to: RemotePath, replacing: Bool = false) async throws {
    try await perform("move", path: from) { backend in
      try backend.requireConnection()
      let sameParent = from.parent == to.parent
      guard sameParent ? backend.capabilities.canRename : backend.capabilities.canMove else {
        throw RemoteError.posix(EROFS)
      }
      if from == to { return }
      let source = try await backend.statUnlocked(from)
      let remoteTarget = try await backend.remoteItem(to)
      let target = backend.staged[to]?.item ?? remoteTarget
      if let target {
        guard replacing else { throw RemoteError.posix(EEXIST) }
        guard backend.capabilities.canDelete else { throw RemoteError.posix(EROFS) }
        guard source.isDirectory == target.isDirectory else {
          throw RemoteError.posix(source.isDirectory ? ENOTDIR : EISDIR)
        }
        if target.isDirectory, !(try await backend.provider.list(to)).isEmpty {
          throw RemoteError.posix(ENOTEMPTY)
        }
      }
      // 先把新内容传完整；目标被删除后改名失败时，源文件仍能用于恢复。
      for path in Array(backend.staged.keys) where Self.contains(from, path) {
        try await backend.flushUnlocked(path)
      }
      let confirmed = try await backend.provider.stat(from)
      guard confirmed.isDirectory == source.isDirectory, confirmed.size == source.size else {
        throw RemoteError.protocolError
      }
      do {
        if remoteTarget != nil { try await backend.provider.remove(to, recursive: false) }
        try await backend.provider.move(from, to: to)
      } catch {
        backend.staged[from]?.retainedForRecovery = true
        let local = backend.staged[from]?.url.path ?? "无本地暂存"
        backend.logger.error(
          "连接 \(backend.connectionID.uuidString, privacy: .public) 移动未完成，源 \(from.value, privacy: .public)，目标 \(to.value, privacy: .public)，本地暂存 \(local, privacy: .public)"
        )
        await backend.invalidate([from, to])
        throw error
      }
      if let replaced = backend.staged.removeValue(forKey: to) {
        try? FileManager.default.removeItem(at: replaced.url)
      }
      for path in Array(backend.staged.keys) where Self.contains(from, path) {
        guard var stage = backend.staged.removeValue(forKey: path) else { continue }
        let destination = try RemotePath(to.value + path.value.dropFirst(from.value.count))
        stage.item.path = destination
        stage.item.name = destination.basename
        stage.retainedForRecovery = false
        backend.staged[destination] = stage
      }
      await backend.invalidate([from, to])
    }
  }
}
