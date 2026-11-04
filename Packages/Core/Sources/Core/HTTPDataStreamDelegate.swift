import Foundation

final class HTTPDataStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private weak var stream: HTTPDataStream?
  private let cookieDomain: String?

  init(stream: HTTPDataStream, cookieDomain: String?) {
    self.stream = stream
    self.cookieDomain = cookieDomain
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    completionHandler(stream?.receive(response) == true ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    stream?.receive(data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    stream?.finish(error)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    guard let source = response.url else { completionHandler(nil); return }
    completionHandler(HTTPRedirectPolicy.request(
      request, from: source, originalMethod: task.originalRequest?.httpMethod ?? "GET",
      cookieDomain: cookieDomain))
  }
}
