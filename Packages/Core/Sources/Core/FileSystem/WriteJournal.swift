import Foundation

// 每个有未上传内容的暂存文件（Writes/<UUID>.data）旁边放一份 <UUID>.json，
// 记下远端路径、远端原来有没有这个文件、内容是否已写完。扩展重启或卸载后，
// 下次挂载靠它把内容接着传上去，不再只剩一份不知道该传到哪的本地文件。
struct WriteJournal: Codable {
  enum State { case writing, ready }

  var path: String
  var existedRemotely: Bool
  // false：写入方还在写（可能写到一半就崩了），不能上传
  var ready: Bool
  // 写入时连的是哪个账号、空间或存储桶；换了就不能把旧内容传过去
  var target: String

  static func url(for data: URL) -> URL {
    data.deletingPathExtension().appendingPathExtension("json")
  }
}

// 扩展里有文件传不上去时，在 App Group 里按连接写一份远端路径清单，并发分布式通知，App 据此提醒用户。
// 清单为空时删掉文件。
public enum PendingUploads {
  public static let notification = Notification.Name("com.seaony.Diskit.pendingUploadsChanged")

  public static func file(dataDirectory: URL, connectionID: UUID) -> URL {
    dataDirectory.appending(path: "PendingUploads", directoryHint: .isDirectory)
      .appending(path: connectionID.uuidString + ".json")
  }

  // 给 App 读：这个连接还没传上去的远端路径
  public static func paths(dataDirectory: URL, connectionID: UUID) -> [String] {
    guard let data = try? Data(contentsOf: file(dataDirectory: dataDirectory, connectionID: connectionID))
    else { return [] }
    return (try? JSONDecoder().decode([String].self, from: data)) ?? []
  }

  static func publish(_ paths: [String], to file: URL, connectionID: UUID) throws {
    let manager = FileManager.default
    if paths.isEmpty {
      if manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
    } else {
      try manager.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(paths).write(to: file, options: .atomic)
    }
    // 沙盒里的分布式通知只能带字符串，不带用户信息
    DistributedNotificationCenter.default().postNotificationName(
      notification, object: connectionID.uuidString, userInfo: nil, deliverImmediately: true)
  }
}

extension RemoteVolumeBackend {
  var writesDirectory: URL {
    cacheRoot.appending(path: connectionID.uuidString).appending(path: "Writes")
  }

  // 先记“正在写”再改内容：改到一半崩了，下次挂载不会把半截内容传上去
  func recordJournal(_ path: RemotePath, _ state: WriteJournal.State) throws {
    guard var stage = staged[path], stage.journal != state else { return }
    let entry = WriteJournal(
      path: path.value, existedRemotely: stage.existedRemotely, ready: state == .ready,
      target: uploadTarget)
    try JSONEncoder().encode(entry).write(to: WriteJournal.url(for: stage.url), options: .atomic)
    stage.journal = state
    staged[path] = stage
  }

  // 连接时接管上次留下的未上传内容，让它们先出现在 Finder 里；上传由 uploadPendingWrites 做
  func adoptJournaledWrites() {
    journalsAdopted = true
    let manager = FileManager.default
    guard
      let files = try? manager.contentsOfDirectory(
        at: writesDirectory, includingPropertiesForKeys: nil)
    else { return }
    let owned = Set(staged.values.map { $0.url.lastPathComponent })
    for data in files where data.pathExtension == "data" && !owned.contains(data.lastPathComponent) {
      let journal = WriteJournal.url(for: data)
      guard manager.fileExists(atPath: journal.path) else {
        // 没有记录的暂存内容要么已传完，要么只是远端文件的副本
        try? manager.removeItem(at: data)
        continue
      }
      do {
        let entry = try JSONDecoder().decode(WriteJournal.self, from: Data(contentsOf: journal))
        let path = try RemotePath(entry.path)
        guard entry.ready else {
          logger.error(
            "连接 \(self.connectionID.uuidString, privacy: .public) 丢弃写到一半中断的内容：\(path.value, privacy: .private)"
          )
          try? manager.removeItem(at: data)
          try? manager.removeItem(at: journal)
          continue
        }
        guard entry.target == uploadTarget else {
          // 位置改成了别的账号或存储桶：不往新的地方传，内容留在本机
          logger.error(
            "连接 \(self.connectionID.uuidString, privacy: .public) 未上传内容属于之前的账号或存储位置，暂不上传：\(path.value, privacy: .private)"
          )
          continue
        }
        guard staged[path] == nil else { continue }
        let attributes = try manager.attributesOfItem(atPath: data.path)
        let item = RemoteItem(
          path: path, name: path.basename, isDirectory: false,
          size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
          modified: attributes[.modificationDate] as? Date ?? now())
        staged[path] = StagedFile(
          url: data, item: item, dirty: true, existedRemotely: entry.existedRemotely,
          journal: .ready)
        logger.info(
          "连接 \(self.connectionID.uuidString, privacy: .public) 接管未上传内容：\(path.value, privacy: .private)"
        )
      } catch {
        logger.error(
          "连接 \(self.connectionID.uuidString, privacy: .public) 读取未上传记录失败，保留 \(journal.path, privacy: .public)"
        )
      }
    }
  }

  // 挂载后把没传上去的内容逐个再传一次；每个文件单独排队，Finder 的操作可以插在中间。
  // 正在被打开或重新写的跳过，由它们自己的关闭来上传。
  public func uploadPendingWrites() async {
    for path in pendingUploads {
      do {
        try await perform("upload-pending", path: path) { backend in
          guard backend.pendingUploads.contains(path), !backend.openedPaths.contains(path) else {
            return
          }
          try await backend.flushUnlocked(path)
          backend.discardStage(path)
        }
      } catch {
        // 失败的保留记录，perform 已记日志；下次挂载或关闭文件时再试
      }
    }
  }

  // 已写完、上传失败的暂存
  var pendingUploads: [RemotePath] {
    staged.filter { $0.value.dirty && $0.value.journal == .ready }.keys.sorted { $0.value < $1.value }
  }

  func reportPendingUploads() {
    guard let pendingUploadsFile, journalsAdopted else { return }
    let paths = pendingUploads.map(\.value)
    guard paths != reportedPendingUploads else { return }
    do {
      try PendingUploads.publish(paths, to: pendingUploadsFile, connectionID: connectionID)
      reportedPendingUploads = paths
    } catch {
      logger.error(
        "连接 \(self.connectionID.uuidString, privacy: .public) 未上传清单写入失败：\(error.localizedDescription, privacy: .private)"
      )
    }
  }

  // 按名字找目录里的条目。Finder 对带重音、日文浊音、韩文的名字发分解形式（NFD），
  // 远端多是合成形式（NFC），字节对不上时再按 Unicode 等价比较
  public static func entries(named name: Data, in items: [RemoteItem]) -> [RemoteItem] {
    let exact = items.filter { Data($0.path.basename.utf8) == name }
    guard exact.isEmpty, let wanted = String(data: name, encoding: .utf8) else { return exact }
    return items.filter { $0.path.basename == wanted }
  }
}

extension Connection {
  // 决定“传到哪里”的参数；昵称、头像、USB 口这类换了也还是同一个地方的不算
  public var uploadTarget: String {
    let volatile: Set<String> = ["nickname", "avatarURL", "accountReady", "usbLocationID", "name", "deviceID"]
    let identity = params.filter { !volatile.contains($0.key) }.sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
    return ([kind.rawValue] + identity).joined(separator: "\n")
  }
}
