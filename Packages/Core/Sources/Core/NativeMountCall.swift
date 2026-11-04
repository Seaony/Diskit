import Foundation
import NetFS

@MainActor protocol MountCalling {
  func start(
    url: URL, mountPoint: URL?, user: String, password: String,
    options: NSMutableDictionary, mountOptions: NSMutableDictionary?,
    completion: @escaping @Sendable (Int32, [String]) -> Void
  ) -> Int32
  func cancel()
  func finished()
}

@MainActor final class NativeMountCall: MountCalling {
  private var request: AsyncRequestID?
  func start(
    url: URL, mountPoint: URL?, user: String, password: String,
    options: NSMutableDictionary, mountOptions: NSMutableDictionary?,
    completion: @escaping @Sendable (Int32, [String]) -> Void
  ) -> Int32 {
    NetFSMountURLAsync(
      url as CFURL, mountPoint.map { $0 as CFURL }, user as CFString,
      password as CFString, options, mountOptions, &request, .main
    ) { status, _, points in
      completion(status, (points as? [String]) ?? [])
    }
  }
  func finished() { request = nil }
  func cancel() {
    if let request { NetFSMountURLCancel(request) }
    request = nil
  }
}
