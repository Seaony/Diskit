import Foundation

// 挂载在扩展进程里做，失败时 App 从系统只能拿到 errno 或 mount 命令的退出码。
// 扩展把真实原因和完整报告写到共享目录，App 挂载失败时读出来显示
public struct MountFailureRecord: Codable, Equatable, Sendable {
  public let message: String
  public let report: String
  public let date: Date

  public init(message: String, report: String, date: Date = Date()) {
    self.message = message
    self.report = report
    self.date = date
  }

  static func file(dataDirectory: URL, connectionID: UUID) -> URL {
    dataDirectory.appending(path: "MountFailures", directoryHint: .isDirectory)
      .appending(path: connectionID.uuidString + ".json")
  }

  // 扩展调用：记下这次挂载失败的原因
  public static func save(_ error: Error, connection: Connection, dataDirectory: URL) throws {
    let record = MountFailureRecord(
      message: HumanError.message(error, kind: connection.kind),
      report: HumanError.report(error, kind: connection.kind))
    let url = file(dataDirectory: dataDirectory, connectionID: connection.id)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(record).write(to: url, options: .atomic)
  }

  // App 调用：取出这次挂载开始之后写的记录，读完就删，避免下次挂载读到旧原因
  public static func take(dataDirectory: URL, connectionID: UUID, since: Date) -> MountFailureRecord? {
    let url = file(dataDirectory: dataDirectory, connectionID: connectionID)
    guard let data = try? Data(contentsOf: url) else { return nil }
    try? FileManager.default.removeItem(at: url)
    guard let record = try? JSONDecoder().decode(MountFailureRecord.self, from: data),
      record.date >= since
    else { return nil }
    return record
  }
}

// App 这边的挂载错误：界面显示扩展记下的真实原因，报告里带上扩展的完整报告和 App 这边的原始错误
public struct ExtensionMountFailure: Error, LocalizedError, CustomNSError {
  public let record: MountFailureRecord
  public let underlying: any Error

  public init(record: MountFailureRecord, underlying: any Error) {
    self.record = record
    self.underlying = underlying
  }

  public var errorDescription: String? { record.message }
  public static var errorDomain: String { "Diskit.ExtensionMountFailure" }
  public var errorCode: Int { (underlying as NSError).code }
  public var errorUserInfo: [String: Any] {
    [NSLocalizedDescriptionKey: record.message, NSUnderlyingErrorKey: underlying]
  }
}
