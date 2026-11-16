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
      guard size == item.size else {
        await invalidate([path])
        throw Self.sizeChanged
      }
      staged[path] = StagedFile(url: file, item: item, dirty: false, existedRemotely: true)
    } catch {
      try? FileManager.default.removeItem(at: file)
      throw error
    }
  }

  public func write(_ path: RemotePath, offset: Int64, data: Data) async throws -> Int {
    try await perform("write", path: path) { backend in
      guard offset >= 0, !offset.addingReportingOverflow(Int64(data.count)).overflow else {
        throw RemoteError.invalidPath
      }
      if LocalMetadataOverlay.handles(path) {
        return try backend.overlay.write(path, offset: offset, data: data)
      }
      try backend.requireConnection()
      try await backend.prepareStage(path)
      try backend.recordJournal(path, .writing)
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
      guard size >= 0 else { throw RemoteError.invalidPath }
      if LocalMetadataOverlay.handles(path) {
        try backend.overlay.resize(path, size: size)
        return
      }
      try backend.requireConnection()
      try await backend.prepareStage(path)
      try backend.recordJournal(path, .writing)
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
      if LocalMetadataOverlay.handles(path) {
        try backend.overlay.setModifiedDate(path, date: date)
        return
      }
      try backend.requireConnection()
      try await backend.prepareStage(path)
      try backend.recordJournal(path, .writing)
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
      backend.attributesByPath.removeAll()
      try backend.overlay.flush(RemotePath("/"))
      // 一个失败也要把其余的都试一遍，每个都记成“已写完”，下次挂载才会接着传
      var failure: Error?
      for path in Array(backend.staged.keys) {
        do { try await backend.flushUnlocked(path) } catch { failure = failure ?? error }
      }
      if let failure { throw failure }
    }
  }

  func flushUnlocked(_ path: RemotePath) async throws {
    attributesByPath.removeValue(forKey: path)
    if LocalMetadataOverlay.handles(path) {
      try overlay.flush(path)
      return
    }
    guard staged[path]?.dirty == true else { return }
    // 走到上传说明写入方已经写完；之后传失败了，下次挂载也能按这份记录接着传
    try recordJournal(path, .ready)
    guard var stage = staged[path] else { return }
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
          ".\(path.basename).diskit-upload-\(UUID().uuidString)")
        hiddenUploads.insert(temporary)
        logger.info(
          "连接 \(self.connectionID.uuidString, privacy: .public) 开始替换，远端暂存 \(temporary.value, privacy: .public)"
        )
        do {
          try await provider.write(temporary, from: uploadFile)
          let uploaded = try await provider.stat(temporary)
          // 传上去的大小不对是这次上传坏了，不是断线；原文件还在，本地内容也留着
          guard !uploaded.isDirectory, uploaded.size == stage.item.size else {
            throw RemoteError.posix(EIO)
          }
          try await provider.remove(path, recursive: false)
          do { try await provider.move(temporary, to: path) } catch {
            // 原文件已经删了：改名再试一次，还不行就让远端暂存露出来，别让文件凭空消失
            do { try await provider.move(temporary, to: path) } catch {
              hiddenUploads.remove(temporary)
              throw error
            }
          }
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
      if stage.journal != nil {
        try? FileManager.default.removeItem(at: WriteJournal.url(for: stage.url))
        stage.journal = nil
      }
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
      backend.openedPaths.remove(path)
      backend.attributesByPath.removeValue(forKey: path)
      backend.dropReadAhead(path)
      try await backend.flushUnlocked(path)
      if backend.staged[path]?.retainedForRecovery == false { backend.discardStage(path) }
      backend.wholeFiles.removeValue(forKey: path)
    }
  }

  public func remove(_ path: RemotePath, recursive: Bool) async throws {
    try await perform("remove", path: path) { backend in
      if LocalMetadataOverlay.handles(path) {
        try backend.overlay.remove(path, recursive: recursive)
        return
      }
      try backend.requireConnection()
      guard backend.capabilities.canDelete else { throw RemoteError.posix(EROFS) }
      if backend.staged[path]?.existedRemotely != false {
        try await backend.provider.remove(path, recursive: recursive)
      }
      for key in Array(backend.staged.keys) where Self.contains(path, key) {
        backend.discardStage(key)
      }
      backend.openedPaths = backend.openedPaths.filter { !Self.contains(path, $0) }
      await backend.invalidate([path])
      do { try backend.overlay.removeMetadata(path) } catch {
        backend.logger.error("远端删除已完成，本地元数据未清理：\(path.value, privacy: .public)")
        throw error
      }
    }
  }

  public func move(_ from: RemotePath, to: RemotePath, replacing: Bool = false) async throws {
    try await perform("move", path: from) { backend in
      let localSource = LocalMetadataOverlay.handles(from)
      guard localSource == LocalMetadataOverlay.handles(to) else {
        throw RemoteError.posix(EXDEV)
      }
      if localSource {
        try backend.overlay.move(from, to: to, replacing: replacing)
        return
      }
      try backend.requireConnection()
      let sameParent = from.parent == to.parent
      guard sameParent ? backend.capabilities.canRename : backend.capabilities.canMove else {
        throw RemoteError.posix(EROFS)
      }
      if from == to { return }
      let source = try await backend.statUnlocked(from)
      var remoteTarget = try await backend.remoteItem(to)
      // 不分大小写的网盘（OneDrive、Dropbox）上 photo.JPG → photo.jpg，查目标会查到源文件自己
      if let found = remoteTarget, found.path == from,
        from.value.caseInsensitiveCompare(to.value) == .orderedSame
      {
        remoteTarget = nil
      }
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
      guard confirmed.isDirectory == source.isDirectory else { throw RemoteError.protocolError }
      guard confirmed.size == source.size else {
        await backend.invalidate([from])
        throw Self.sizeChanged
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
      backend.discardStage(to)
      for path in Array(backend.staged.keys) where Self.contains(from, path) {
        guard var stage = backend.staged.removeValue(forKey: path) else { continue }
        let destination = try RemotePath(to.value + path.value.dropFirst(from.value.count))
        stage.item.path = destination
        stage.item.name = destination.basename
        stage.retainedForRecovery = false
        backend.staged[destination] = stage
      }
      let opened = backend.openedPaths.filter { Self.contains(from, $0) }
      backend.openedPaths = backend.openedPaths.filter {
        !Self.contains(from, $0) && !Self.contains(to, $0)
      }
      for path in opened {
        backend.openedPaths.insert(
          try RemotePath(to.value + path.value.dropFirst(from.value.count)))
      }
      await backend.invalidate([from, to])
      do { try backend.overlay.moveMetadata(from, to: to) } catch {
        backend.logger.error(
          "远端移动已完成，本地元数据未迁移：\(from.value, privacy: .public) → \(to.value, privacy: .public)")
        throw error
      }
    }
  }

  // 丢掉暂存：本地内容和旁边的记录一起删
  func discardStage(_ path: RemotePath) {
    guard let stage = staged.removeValue(forKey: path) else { return }
    do { try FileManager.default.removeItem(at: stage.url) } catch {
      logger.error("本地暂存未清理：\(stage.url.path, privacy: .public)")
    }
    if stage.journal != nil {
      try? FileManager.default.removeItem(at: WriteJournal.url(for: stage.url))
    }
  }
}
