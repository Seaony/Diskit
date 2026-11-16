import Foundation

// Finder 复制文件时每次只要 1 MiB，每次单独请求都要等一个来回，还得排队，速度只有单连接的零头。
// 认出是顺序往下读之后，就用几条连接同时把后面几段提前下好，Finder 读到时直接给。
struct ReadAhead {
  struct Segment {
    let download: Task<Data, Error>
    // 只表示下完了（成功失败都算），后面的段等它而不是等 download，免得一直握着这段的数据
    let finished: Task<Void, Never>
  }
  // 这一轮顺序读从哪开始；连续读够一段才预读，生成缩略图这类只读开头几 KB 的不会触发
  let runStart: Int64
  // 下一次顺序读应当从这里开始
  var next: Int64
  // 开始预读时的文件属性；大小或修改时间变了，提前下好的内容就作废
  let item: RemoteItem
  // 段起点 → 这一段的下载
  var segments: [Int64: Segment] = [:]
  var lastUsed: Date
  // 预读出过错就不再预读这个文件，免得每次都白发一批请求
  var disabled = false

  func cancel() { for segment in segments.values { segment.download.cancel() } }
}

extension RemoteVolumeBackend {
  // 同一个卷同时只给一个文件预读：线路的总速度就这么多，多给几个文件预读不会更快，
  // 只会多占内存（每个文件最多占「(连接数 + 2) × 段大小」）
  static let readAheadFiles = 1
  // 预读着的文件这么久没读就让给别的文件
  static let readAheadIdle: TimeInterval = 10

  // 是顺序读并且能预读时返回读到的内容；返回 nil 表示照常单独请求
  func readAhead(_ path: RemotePath, item: RemoteItem, offset: Int64, length: Int) async throws
    -> Data?
  {
    let connections = capabilities.readAheadConnections
    guard connections > 0, let state = readAheads[path] else { return nil }
    guard !state.disabled, state.next == offset, state.item == item else {
      if !state.disabled { dropReadAhead(path) }
      return nil
    }
    guard offset - state.runStart >= readAheadAfterBytes else { return nil }
    let segment = readAheadSegmentBytes
    let end = min(item.size, offset + Int64(length))
    let first = offset / segment * segment
    // 往后准备「连接数 + 2」段，但同时只下「连接数」段：前面的下完一段，后面才接着开一段，
    // 这样一直有这么多条连接在下，不用等 Finder 读到才补
    let last = max((end - 1) / segment, first / segment + Int64(connections) + 1) * segment
    var updated = state
    for (start, old) in updated.segments where start < first {
      old.download.cancel()
      updated.segments.removeValue(forKey: start)
    }
    for start in stride(from: first, through: last, by: Int(segment)) where start < item.size {
      guard updated.segments[start] == nil else { continue }
      let range = start..<min(item.size, start + segment)
      let previous = updated.segments[start - Int64(connections) * segment]?.finished
      let download = Task.detached { [provider] in
        await previous?.value
        try Task.checkCancellation()
        return try await Self.download(provider, path, range: range)
      }
      updated.segments[start] = ReadAhead.Segment(
        download: download, finished: Task { _ = try? await download.value })
    }
    updated.lastUsed = now()
    readAheads[path] = updated

    var result = Data(capacity: Int(end - offset))
    var position = offset
    do {
      while position < end {
        let start = position / segment * segment
        guard let task = updated.segments[start]?.download else { throw RemoteError.protocolError }
        let data = try await withTaskCancellationHandler {
          try await task.value
        } onCancel: {
          task.cancel()
        }
        let from = Int(position - start)
        let to = min(data.count, Int(end - start))
        guard from < to else { throw RemoteError.protocolError }
        result.append(data[from..<to])
        position = start + Int64(to)
      }
    } catch {
      // 读的人取消了就照实报，这个文件下次重新开始预读；预读本身出错（连接断了、链接过期）就退回单独请求
      if Task.isCancelled {
        dropReadAhead(path)
        throw CancellationError()
      }
      logger.error(
        "连接 \(self.connectionID.uuidString, privacy: .public) 预读失败，改为逐段读取：\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)"
      )
      dropReadAhead(path)
      readAheads[path] = ReadAhead(
        runStart: offset, next: offset, item: item, lastUsed: now(), disabled: true)
      return nil
    }
    readAheads[path]?.next = end
    return result
  }

  // 单独请求读完一段后记下位置，下一次从这里接着读就开始预读
  func noteRead(_ path: RemotePath, item: RemoteItem, start: Int64, end: Int64) {
    guard capabilities.readAheadConnections > 0, openedPaths.contains(path) else { return }
    if readAheads[path] != nil {
      readAheads[path]?.next = end
      readAheads[path]?.lastUsed = now()
      return
    }
    let busy = readAheads.filter { !$0.value.disabled && $0.key != path }
    if busy.count >= Self.readAheadFiles {
      // 满了：最久没读的那个闲了一阵才让出来，否则这个文件先不预读
      guard let oldest = busy.min(by: { $0.value.lastUsed < $1.value.lastUsed }),
        now().timeIntervalSince(oldest.value.lastUsed) >= Self.readAheadIdle
      else { return }
      dropReadAhead(oldest.key)
    }
    readAheads[path] = ReadAhead(runStart: start, next: end, item: item, lastUsed: now())
  }

  func setReadAhead(segment: Int64, after: Int64) {
    readAheadSegmentBytes = segment
    readAheadAfterBytes = after
  }

  func dropReadAhead(_ path: RemotePath) {
    readAheads.removeValue(forKey: path)?.cancel()
  }

  func dropAllReadAheads() {
    for state in readAheads.values { state.cancel() }
    readAheads.removeAll()
  }

  static func download(
    _ provider: any RemoteFileProvider, _ path: RemotePath, range: Range<Int64>
  ) async throws -> Data {
    let expected = Int(range.upperBound - range.lowerBound)
    var data = Data(capacity: expected)
    for try await chunk in try await provider.read(path, range: range) {
      try Task.checkCancellation()
      data.append(chunk.prefix(expected - data.count))
      if data.count == expected { break }
    }
    // 少给了说明文件变了或连接被截断，交给单独请求重新读
    guard data.count == expected else { throw RemoteError.protocolError }
    return data
  }
}
