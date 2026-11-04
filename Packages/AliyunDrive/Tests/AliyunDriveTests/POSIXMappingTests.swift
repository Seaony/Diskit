import Core
import Foundation
import Testing

@testable import AliyunDrive

@Test func aliyunErrorsPreservePOSIXMeaningAndDescription() {
  let cases: [(AliyunError, Int32)] = [
    (.missingConfiguration, EINVAL), (.invalidState, EACCES), (.loginRequired, EACCES),
    (.invalidResponse, EIO), (.rateLimited, EAGAIN), (.authorizationFailed(400), EINVAL),
    (.authorizationFailed(401), EACCES), (.authorizationFailed(403), EACCES),
    (.authorizationFailed(429), EAGAIN), (.authorizationFailed(500), EIO),
    (.authorizationFailed(503), EAGAIN), (.authorizationFailed(504), ETIMEDOUT),
  ]
  for (error, code) in cases {
    let bridged = error as NSError
    #expect(bridged.domain == NSPOSIXErrorDomain)
    #expect(bridged.code == Int(code))
    #expect(bridged.localizedDescription == error.errorDescription)
  }
}
