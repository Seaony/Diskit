import Core
import Foundation
import OSLog

public enum ADBProviderFactory {
  private static let logger = Logger(subsystem: "com.seaony.Kayoi", category: "ADBTransport")
  public static func make(for connection: Connection) async throws -> ADBProvider {
    let session = try await makeSession(for: connection)
    return ADBProvider(session: session, reconnect: { try await makeSession(for: connection) })
  }
  private static func makeSession(for connection: Connection) async throws -> ADBSession {
    if connection.kind == .androidUSB {
      logger.info("连接方式：USB")
      return try ADBProvider.usbSession(serial: connection.params["serial"] ?? "")
    }
    guard connection.kind == .androidWiFi, let guid = connection.params["guid"], !guid.isEmpty
    else { throw RemoteError.invalidPath }
    let usb = ADBUSB.devices()
    if let serial = WirelessSelection.serial(fromGUID: guid),
      usb.contains(where: { $0.serial == serial })
    {
      logger.info("连接方式：USB（优先于同机 Wi-Fi）")
      return try ADBProvider.usbSession(serial: serial)
    }
    let endpoint = try await WirelessDiscovery.resolve(guid: guid)
    logger.info("连接方式：Wi-Fi")
    let transport = try NetworkTransport(endpoint: endpoint, startTLS: true)
    do {
      try await transport.start()
      return ADBSession(transport: transport, initialConnectSent: true)
    } catch {
      await transport.close()
      throw error
    }
  }
}
