import Core
import Foundation
import OSLog

public enum ADBProviderFactory {
  private static let logger = Logger(subsystem: "com.seaony.Kayoi", category: "ADBTransport")
  public static func make(for connection: Connection) async throws -> ADBProvider {
    if connection.kind == .androidUSB {
      logger.info("连接方式：USB")
      return try ADBProvider.usb(serial: connection.params["serial"] ?? "")
    }
    guard connection.kind == .androidWiFi, let guid = connection.params["guid"], !guid.isEmpty
    else { throw RemoteError.invalidPath }
    let usb = ADBUSB.devices()
    if let serial = WirelessSelection.serial(fromGUID: guid),
      usb.contains(where: { $0.serial == serial })
    {
      logger.info("连接方式：USB（优先于同机 Wi-Fi）")
      return try ADBProvider.usb(serial: serial)
    }
    let endpoint = try await WirelessDiscovery.resolve(guid: guid)
    logger.info("连接方式：Wi-Fi")
    let transport = try NetworkTransport(endpoint: endpoint, startTLS: true)
    do {
      try await transport.start()
      return ADBProvider(session: ADBSession(transport: transport, initialConnectSent: true))
    } catch {
      await transport.close()
      throw error
    }
  }
}
