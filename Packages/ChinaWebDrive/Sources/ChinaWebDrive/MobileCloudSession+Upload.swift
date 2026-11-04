import Core
import Foundation

extension MobileCloudSession {
  public func unsignedUpload(_ request: URLRequest) async throws -> HTTPResponse {
    guard let url = request.url, url.scheme == "https", url.user == nil,
      url.password == nil
    else { throw MobileCloudError.invalidResponse }
    var unsigned = request
    unsigned.setValue(nil, forHTTPHeaderField: "Authorization")
    unsigned.setValue(nil, forHTTPHeaderField: "Cookie")
    return try await transport.send(unsigned)
  }
}
