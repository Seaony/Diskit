import Core
import Foundation
import OSLog

public enum ADBProviderFactory {
  private static let logger = Logger(subsystem: "com.seaony.Kayoi", category: "ADBTransport")
  public static func make(for connection: Connection, identity: ADBIdentity = ADBIdentity()) async throws -> ADBProvider {
    try await make(
      for: connection, devices: { ADBUSB.devices() },
      usb: { try ADBProvider.usbSession(device: $0, identity: identity) },
      wireless: { try await wirelessSession(guid: $0, identity: identity) })
  }

  static func make(
    for connection: Connection,
    devices: @escaping @Sendable () -> [ADBDevice],
    usb: @escaping @Sendable (ADBDevice) async throws -> ADBSession,
    wireless: @escaping @Sendable (String) async throws -> ADBSession
  ) async throws -> ADBProvider {
    let create: @Sendable () async throws -> ADBSession = {
      try await makeSession(for: connection, devices: devices(), usb: usb, wireless: wireless)
    }
    return try await ADBProvider(session: create(), reconnect: create)
  }

  private static func makeSession(
    for connection: Connection, devices: [ADBDevice],
    usb: @Sendable (ADBDevice) async throws -> ADBSession,
    wireless: @Sendable (String) async throws -> ADBSession
  ) async throws -> ADBSession {
    if connection.kind == .androidUSB {
      logger.info("连接方式：USB")
      return try await usb(ADBUSB.select(params: connection.params, devices: devices))
    }
    guard connection.kind == .androidWiFi, let guid = connection.params["guid"], !guid.isEmpty
    else { throw RemoteError.invalidPath }
    if let serial = WirelessSelection.serial(fromGUID: guid),
      let device = try? ADBUSB.select(params: ["serial": serial], devices: devices)
    {
      logger.info("连接方式：USB（优先于同机 Wi-Fi）")
      return try await usb(device)
    }
    return try await wireless(guid)
  }

  private static func wirelessSession(guid: String, identity: ADBIdentity) async throws -> ADBSession {
    let endpoint = try await WirelessDiscovery.resolve(guid: guid)
    logger.info("连接方式：Wi-Fi")
    let transport = try NetworkTransport(endpoint: endpoint, startTLS: true, identity: identity)
    do {
      try await transport.start()
      return ADBSession(transport: transport, identity: identity, initialConnectSent: true)
    } catch {
      await transport.close()
      throw error
    }
  }
}
