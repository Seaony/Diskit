import Core
import Foundation
import OSLog

public enum ADBProviderFactory {
  private static let logger = Logger(subsystem: "com.seaony.Diskit", category: "ADBTransport")
  public static func make(for connection: Connection, identity: ADBIdentity = ADBIdentity()) async throws -> ADBProvider {
    try await make(
      for: connection, devices: { ADBUSB.devices() },
      usb: { try ADBProvider.usbSession(device: $0, identity: identity) },
      wireless: { try await wirelessSession(guid: $0, identity: identity) },
      server: { ADBServerSession(serial: $0) })
  }

  static func make(
    for connection: Connection,
    devices: @escaping @Sendable () -> [ADBDevice],
    usb: @escaping @Sendable (ADBDevice) async throws -> any ADBStreamSession,
    wireless: @escaping @Sendable (String) async throws -> any ADBStreamSession,
    server: @escaping @Sendable (String) -> ADBServerSession
  ) async throws -> ADBProvider {
    let create: @Sendable () async throws -> any ADBStreamSession = {
      try await makeSession(
        for: connection, devices: devices(), usb: usb, wireless: wireless, server: server)
    }
    return try await ADBProvider(stream: create(), reconnect: create)
  }

  private static func makeSession(
    for connection: Connection, devices: [ADBDevice],
    usb: @Sendable (ADBDevice) async throws -> any ADBStreamSession,
    wireless: @Sendable (String) async throws -> any ADBStreamSession,
    server: @Sendable (String) -> ADBServerSession
  ) async throws -> any ADBStreamSession {
    if connection.kind == .androidUSB {
      logger.info("连接方式：USB")
      let device = try ADBUSB.select(params: connection.params, devices: devices)
      return try await usbOrServer(device, among: devices, usb: usb, server: server)
    }
    guard connection.kind == .androidWiFi, let guid = connection.params["guid"], !guid.isEmpty
    else { throw RemoteError.invalidPath }
    if let serial = WirelessSelection.serial(fromGUID: guid),
      let device = try? ADBUSB.select(params: ["serial": serial], devices: devices)
    {
      logger.info("连接方式：USB（优先于同机 Wi-Fi）")
      return try await usbOrServer(device, among: devices, usb: usb, server: server)
    }
    return try await wireless(guid)
  }

  // 手机的 USB 调试接口被占用时，多半是电脑上的 adb server 拿着；它连着这台手机就经它读写
  private static func usbOrServer(
    _ device: ADBDevice, among devices: [ADBDevice],
    usb: @Sendable (ADBDevice) async throws -> any ADBStreamSession,
    server: @Sendable (String) -> ADBServerSession
  ) async throws -> any ADBStreamSession {
    do {
      return try await usb(device)
    } catch let error as RemoteError where error.errno == EBUSY {
      // adb server 只能按序列号找手机；序列号为空或有两台相同时会找错手机，不转发
      guard !device.serial.isEmpty, devices.filter({ $0.serial == device.serial }).count == 1
      else { throw error }
      let session = server(device.serial)
      switch try await session.availability() {
      case .ready:
        logger.info("连接方式：USB（接口被占用，经电脑上的 adb server 转发）")
        return session
      case .unauthorized: throw RemoteError.unauthorized
      // 占着接口的不是 adb server（或它没连着这台手机），把是谁占着报出来
      case .unavailable: throw error
      }
    }
  }

  private static func wirelessSession(guid: String, identity: ADBIdentity) async throws -> any ADBStreamSession {
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
