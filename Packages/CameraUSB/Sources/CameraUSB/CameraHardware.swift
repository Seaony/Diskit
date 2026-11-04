import Core
import Foundation

@MainActor protocol CameraHardwareItem: AnyObject {
  var name: String? { get }
  var handle: UInt32 { get }
  var size: Int64? { get }
  var modified: Date? { get }
  var created: Date? { get }
  var isFolder: Bool { get }
  var children: [any CameraHardwareItem]? { get }
  func read(offset: Int64, length: Int, completion: @escaping @Sendable (Data?, Error?) -> Void)
}

@MainActor protocol CameraHardware: AnyObject {
  var isOpen: Bool { get }
  var catalogProgress: Int { get }
  var locked: Bool { get }
  var deleteSupported: Bool { get }
  var contents: [any CameraHardwareItem]? { get }
  var removed: (() -> Void)? { get set }
  var ready: (() -> Void)? { get set }
  func start()
  func stop()
  func open(completion: @escaping @Sendable (Error?) -> Void)
  func close(completion: @escaping @Sendable (Error?) -> Void)
  func delete(
    _ items: [any CameraHardwareItem], failed: @escaping @Sendable () -> Void,
    completion: @escaping @Sendable (Error?) -> Void)
}
