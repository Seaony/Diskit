import Core
import Foundation
import IOKit
import Testing

@testable import ADB

// 假的 adb server：每次拨号给一条新连接，按 SERVICES.TXT 的格式回应请求
private actor FakeADBServer {
  var devices = "same\tdevice\n"
  var services: [String: Data] = ["shell,v2,raw:ok": Data("hello".utf8)]
  var unknownMessage = "closed: unknown service"
  private(set) var requests: [String] = []
  private(set) var dialed = 0
  func record(_ text: String) { requests.append(text) }
  func dial() -> any ADBTransport {
    dialed += 1
    return FakeServerConnection(server: self)
  }
  func reply(to text: String) -> (Data, Bool) {
    func ok(_ body: String) -> Data { Data(("OKAY" + String(format: "%04x", body.utf8.count) + body).utf8) }
    switch text {
    case "host:devices": return (ok(devices), true)
    case "host-serial:same:features": return (ok("shell_v2,stat_v2,ls_v2"), true)
    case "host:transport:same": return (Data("OKAY".utf8), false)
    default:
      if let body = services[text] { return (Data("OKAY".utf8) + body, true) }
      // 其它 shell v2 命令：没有输出，退出码 0
      if text.hasPrefix("shell,v2,raw:") { return (Data("OKAY".utf8) + Data([3, 1, 0, 0, 0, 0]), true) }
      let message = unknownMessage
      return (Data(("FAIL" + String(format: "%04x", message.utf8.count) + message).utf8), true)
    }
  }
}

private actor FakeServerConnection: ADBTransport {
  let server: FakeADBServer
  private var incoming = Data()
  private var outgoing = Data()
  private var ended = false
  init(server: FakeADBServer) { self.server = server }
  func write(_ data: Data, timeout: TimeInterval) async throws {
    incoming.append(data)
    while incoming.count >= 4, let length = Int(String(decoding: incoming.prefix(4), as: UTF8.self), radix: 16),
      incoming.count >= 4 + length
    {
      let text = String(decoding: incoming.dropFirst(4).prefix(length), as: UTF8.self)
      incoming.removeFirst(4 + length)
      await server.record(text)
      let (reply, end) = await server.reply(to: text)
      outgoing.append(reply)
      ended = end
    }
  }
  func read(count: Int, timeout: TimeInterval) async throws -> Data {
    guard !outgoing.isEmpty else { throw ended ? RemoteError.notConnected : RemoteError.posix(ETIMEDOUT) }
    let bytes = outgoing.prefix(count)
    outgoing.removeFirst(bytes.count)
    return Data(bytes)
  }
  func close() async {}
}

@Test func adbServerSessionSelectsThePhoneAndStreamsUntilTheServerCloses() async throws {
  let server = FakeADBServer()
  let session = ADBServerSession(serial: "same", dial: { await server.dial() })
  #expect(try await session.availability() == .ready)
  try await session.connect()
  #expect(await session.features == ["shell_v2", "stat_v2", "ls_v2"])
  try await session.open("shell,v2,raw:ok")
  #expect(try await session.readExactly(2) == Data("he".utf8))
  #expect(try await session.readChunk() == Data("llo".utf8))
  #expect(try await session.readChunk() == nil)
  try await session.closeService()
  #expect(
    await server.requests == [
      "host:devices", "host-serial:same:features", "host:transport:same", "shell,v2,raw:ok",
    ])
  // 每个服务各用一条连接：查设备、查特性、开服务各拨一次
  #expect(await server.dialed == 3)
}

@Test func adbServerRefusalShowsTheServersOwnMessage() async throws {
  let server = FakeADBServer()
  let session = ADBServerSession(serial: "same", dial: { await server.dial() })
  await #expect(
    throws: RemoteError.failed(
      EIO, LF("电脑上的 adb server 拒绝了请求“%@”：%@", "bogus:", "closed: unknown service"))
  ) { try await session.open("bogus:") }
  // 失败后通道已释放，可以接着开下一个服务
  try await session.open("shell,v2,raw:ok")
}

@Test(arguments: [("same\tunauthorized\n", "unauthorized"), ("other\tdevice\n", "unavailable")])
func adbServerAvailabilityFollowsTheDeviceState(list: String, expected: String) async throws {
  let server = FakeADBServer()
  await server.setDevices(list)
  let session = ADBServerSession(serial: "same", dial: { await server.dial() })
  #expect("\(try await session.availability())" == expected)
  let missing = ADBServerSession(serial: "same", dial: { throw RemoteError.posix(ECONNREFUSED) })
  #expect(try await missing.availability() == .unavailable)
}

extension FakeADBServer {
  func setDevices(_ value: String) { devices = value }
  func setUnknownMessage(_ value: String) { unknownMessage = value }
}

@Test(arguments: ["same\tdevice\n", "same\tunauthorized\n", ""])
func occupiedUSBFallsBackToTheRunningADBServer(list: String) async throws {
  let server = FakeADBServer()
  await server.setDevices(list)
  let device = ADBDevice(serial: "same", name: "A", registryID: 1, locationID: 10)
  let make = {
    try await ADBProviderFactory.make(
      for: Connection(kind: .androidUSB, params: device.connectionParameters(in: [device])),
      devices: { [device] }, usb: { _ in throw USBTransport.occupied(by: "pid 1, adb") },
      wireless: { _ in throw RemoteError.notConnected },
      server: { ADBServerSession(serial: $0, dial: { await server.dial() }) })
  }
  switch list {
  case "same\tdevice\n":
    let provider = try await make()
    try await provider.connect()
    #expect(await server.requests.contains("host-serial:same:features"))
  case "same\tunauthorized\n":
    await #expect(throws: RemoteError.unauthorized) { _ = try await make() }
  default:
    await #expect(throws: USBTransport.occupied(by: "pid 1, adb")) { _ = try await make() }
  }
}

@Test func usbOpenErrorsKeepTheRealIOKitReason() {
  // 本机实测：adb server 占着接口时 IOUSBHost 报 0xe00002c9（internal error），原因只能从注册表看
  let failure = NSError(
    domain: "IOUSBHostErrorDomain", code: Int(Int32(bitPattern: 0xe000_02c9)),
    userInfo: [NSLocalizedFailureReasonErrorKey: "Failed [super init]"])
  let mapped = USBTransport.mappedOpenError(failure) as NSError
  #expect(mapped.code == Int(EIO))
  #expect(mapped.localizedDescription.contains("internal error"))
  #expect(mapped.localizedDescription.contains("0xe00002c9"))
  #expect(mapped.localizedDescription.contains("Failed [super init]"))
}

@Test func usbOccupantNamesTheProgramAndProcess() {
  #expect(
    USBTransport.occupied(by: "pid 14435, adb")
      == .failed(EBUSY, LF("手机的 USB 调试接口正被电脑上的“%@”（进程 %@）占用，关掉它后重试", "adb", "14435")))
  #expect(
    USBTransport.occupied(by: "AppleUSBHostThing")
      == .failed(EBUSY, LF("手机的 USB 调试接口正被电脑上的“%@”占用，关掉它后重试", "AppleUSBHostThing")))
}

@Test func duplicateSerialsNeverFallBackToTheADBServer() async throws {
  let server = FakeADBServer()
  let devices = [
    ADBDevice(serial: "same", name: "A", registryID: 1, locationID: 10),
    ADBDevice(serial: "same", name: "B", registryID: 2, locationID: 20),
  ]
  let occupied = USBTransport.occupied(by: "pid 1, adb")
  // adb server 只认序列号，两台同号时可能连错手机，直接报出占用者
  await #expect(throws: occupied) {
    _ = try await ADBProviderFactory.make(
      for: Connection(kind: .androidUSB, params: devices[1].connectionParameters(in: devices)),
      devices: { devices }, usb: { _ in throw occupied },
      wireless: { _ in throw RemoteError.notConnected },
      server: { ADBServerSession(serial: $0, dial: { await server.dial() }) })
  }
  #expect(await server.dialed == 0)
}

@Test func adbServerReportsAMissingPhoneAsDisconnected() async throws {
  let server = FakeADBServer()
  let session = ADBServerSession(serial: "gone", dial: { await server.dial() })
  await server.setUnknownMessage("device 'gone' not found")
  do {
    try await session.open("sync:")
    Issue.record("应该失败")
  } catch let error as RemoteError {
    #expect(error.errno == ENODEV)
    #expect(error.localizedDescription.contains("device 'gone' not found"))
  }
}
