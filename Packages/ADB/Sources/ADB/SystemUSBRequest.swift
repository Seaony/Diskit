import Foundation
import IOKit
import IOUSBHost

extension USBIORequest {
  static func perform(
    pipe: IOUSBHostPipe, buffer: NSMutableData?, timeout: TimeInterval,
    isolation: isolated (any Actor)? = #isolation
  ) async throws -> Int {
    let storage = USBRequestStorage(pipe: pipe, buffer: buffer)
    let request = USBIORequest(
      enqueue: { completion in
        try storage.pipe.enqueueIORequest(with: storage.buffer, completionTimeout: timeout) {
          status, count in
          // 回调结束前系统仍可能引用缓冲区。
          withExtendedLifetime(storage) {
            if status == kIOReturnSuccess {
              completion(.success(count))
            } else {
              completion(.failure(NSError(domain: NSOSStatusErrorDomain, code: Int(status))))
            }
          }
        }
      },
      abort: { try? storage.pipe.__abort(with: .asynchronous) })
    return try await request.run()
  }
}

private final class USBRequestStorage: @unchecked Sendable {
  let pipe: IOUSBHostPipe
  let buffer: NSMutableData?
  init(pipe: IOUSBHostPipe, buffer: NSMutableData?) {
    self.pipe = pipe
    self.buffer = buffer
  }
}
