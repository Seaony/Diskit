@testable import Core
import CoreTestSupport
import Synchronization
import Foundation
import Testing

@testable import S3Drive

private actor ConcurrencyProbe: HTTPTransport {
  let gate = BatchGate(expected: 16)
  var active = 0
  var maximum = 0
  var count = 0
  func send(_ request: URLRequest) async throws -> HTTPResponse {
    active += 1
    maximum = max(maximum, active)
    count += 1
    defer { active -= 1 }
    try await gate.enter()
    return HTTPResponse(status: 200)
  }
}

@Test(arguments: [0, 1, 2])
func s3AccountLimitsRequestsAcrossProviders(configurationVariant: Int) async throws {
  let transport = ConcurrencyProbe()
  let endpoint = URL(string: "https://\(UUID().uuidString.lowercased()).example.invalid")!
  func makeProvider(bucket: String, endpoint: URL) -> S3Provider {
    S3Provider(
      configuration: S3Configuration(
        endpoint: endpoint, region: "us-east-1", bucket: bucket, accessKey: "same-account",
        secretKey: "test"), transport: transport)
  }
  let first = makeProvider(bucket: "first", endpoint: endpoint)
  let alias = URL(string: "https://\(endpoint.host!.uppercased()):443/")!
  let second =
    configurationVariant == 0
    ? first : makeProvider(bucket: "second", endpoint: configurationVariant == 2 ? alias : endpoint)
  try await first.connect()
  try await second.connect()
  let limit = HTTPConcurrencyLimit.shared(for: "s3:\(endpoint.host!):443|same-account")
  await limit.observeQueue { transport.gate.observeQueue($0) }
  try await withThrowingTaskGroup(of: Void.self) { group in
    for index in 0..<16 {
      group.addTask { _ = try await (index.isMultiple(of: 2) ? first : second).spaceInfo() }
    }
    try await group.waitForAll()
  }
  #expect(await transport.maximum <= 4)
  #expect(await transport.maximum > 1)
  #expect(await transport.count == 16)
  #expect(await transport.active == 0)
}

private final class BatchGate: Sendable {
  private struct State { var entered = 0; var queued = 0 }
  private let state = Mutex(State())
  private let expected: Int
  private let released = TestEvent()
  init(expected: Int) { self.expected = expected }
  func observeQueue(_ count: Int) {
    let ready = state.withLock { value in
      value.queued = count
      return value.entered + value.queued >= expected || value.entered > 4
    }
    if ready { released.signal() }
  }
  func enter() async throws {
    let ready = state.withLock { value in
      value.entered += 1
      return value.entered + value.queued >= expected || value.entered > 4
    }
    if ready { released.signal() }
    try await released.wait()
  }
}
