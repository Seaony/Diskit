import Foundation

@MainActor protocol RicohHardwareFile: AnyObject {
  var size: Int64 { get }
  func read(offset: Int64, length: Int64, completion: @escaping @Sendable (Data?, Error?) -> Void)
}

@MainActor protocol RicohHardwareItem: AnyObject {
  var handle: UInt32 { get }
  var name: String? { get }
  var modified: Date? { get }
  var created: Date? { get }
  var file: (any RicohHardwareFile)? { get }
  var children: [any RicohHardwareItem]? { get }
}

@MainActor protocol RicohCameraHardware: AnyObject {
  var hasOpenSession: Bool { get }
  var isLocked: Bool { get }
  var capabilities: [String] { get }
  var catalogPercent: Int { get }
  var contents: [any RicohHardwareItem]? { get }
  var removed: (@MainActor () -> Void)? { get set }
  var catalogReady: (@MainActor () -> Void)? { get set }
  func start()
  func stop()
  func open(completion: @escaping @Sendable (Error?) -> Void)
  func close(completion: @escaping @Sendable (Error?) -> Void)
  func command(_ data: Data, completion: @escaping @Sendable (Data, Data, Error?) -> Void)
  func delete(
    _ files: [any RicohHardwareFile], failed: @escaping @Sendable () -> Void,
    completion: @escaping @Sendable (Error?) -> Void) throws
}
