import Core
import Foundation
import Network

final class ADBStartTLS: NWProtocolFramerImplementation {
  static let label = "Diskit ADB STLS"
  static let definition = NWProtocolFramer.Definition(implementation: ADBStartTLS.self)
  required init(framer: NWProtocolFramer.Instance) {}
  func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
    framer.writeOutput(data: ADBStartTLSProtocol.hello)
    framer.scheduleWakeup(wakeupTime: .milliseconds(UInt64(RemoteTimeout.deviceRequest * 1000)))
    return .willMarkReady
  }
  static func response(to header: Data) throws -> Data {
    try ADBStartTLSProtocol.response(to: header)
  }
  func handleInput(framer: NWProtocolFramer.Instance) -> Int {
    var header: Data?
    let parsed = framer.parseInput(minimumIncompleteLength: 24, maximumLength: 24) { bytes, _ in
      guard let bytes, bytes.count >= 24 else { return 0 }
      header = Data(bytes.prefix(24))
      return 24
    }
    guard parsed, let header else { return 24 }
    do {
      guard let tls = framer.options["tls"] as? NWProtocolTLS.Options else {
        throw RemoteError.protocolError
      }
      framer.writeOutput(data: try Self.response(to: header))
      try framer.prependApplicationProtocol(options: tls)
      framer.scheduleWakeup(wakeupTime: .forever)
      framer.passThroughInput()
      framer.passThroughOutput()
      framer.markReady()
    } catch { framer.markFailed(error: .posix(.EPROTO)) }
    return 0
  }
  func handleOutput(
    framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int,
    isComplete: Bool
  ) {
    do { try framer.writeOutputNoCopy(length: messageLength) } catch {
      framer.markFailed(error: .posix(.EIO))
    }
  }
  func wakeup(framer: NWProtocolFramer.Instance) { framer.markFailed(error: .posix(.ETIMEDOUT)) }
  func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
  func cleanup(framer: NWProtocolFramer.Instance) {}
}
