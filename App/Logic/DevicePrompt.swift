import ADB
import Core
import Foundation
import UserNotifications

// 插上还没添加的手机或相机时问要不要添加：同意就保存并设为插上自动连接，以后插上直接连接；
// 选“不用了”只在这次插着时不再问，拔掉再插上会重新问（也可在添加窗口的“已发现”里手动添加）
enum DevicePrompt {
  static let category = "device-found"
  static let mountAction = "mount"
  static let declineAction = "decline"
  static let keyInfo = "deviceKey"
  static let kinds: Set<ConnectionKind> = [.androidUSB, .androidMTP, .cameraUSB]

  // 优先用序列号，换个 USB 口也认得出是同一台
  static func key(_ item: DiscoveredItem) -> String {
    let serial = item.connection?.params["serial"] ?? ""
    return serial.isEmpty ? item.id : item.kind.rawValue + ":" + serial
  }

  static func notificationID(_ key: String) -> String { "device-found-" + key }
}

extension AppModel {
  // 插着、还没保存、能直接连接的设备
  private var pluggedDevices: [DiscoveredItem] {
    discoveredItems.filter { DevicePrompt.kinds.contains($0.kind) && $0.connection != nil }
  }

  // 可以问的设备：这次插上后还没点过“不用了”
  private var promptableDevices: [DiscoveredItem] {
    pluggedDevices.filter { !declinedDevices.contains(DevicePrompt.key($0)) }
  }

  // 面板顶部要问的那台设备
  var devicePrompt: DiscoveredItem? { promptableDevices.first }

  // 设备变化后调用：新出现的设备各发一次通知；拔掉的设备忘掉，下次插上再提醒
  func refreshDevicePrompts() {
    // 拔掉的设备忘掉“不用了”，下次插上重新问
    declinedDevices.formIntersection(pluggedDevices.map(DevicePrompt.key))
    let current = promptableDevices
    let keys = Set(current.map(DevicePrompt.key))
    for gone in notifiedDevices.subtracting(keys) {
      system.removeNotifications([DevicePrompt.notificationID(gone)])
    }
    notifiedDevices.formIntersection(keys)
    if let key = mountingPromptDevice, !keys.contains(key) { mountingPromptDevice = nil }
    devicePromptErrors = devicePromptErrors.filter { keys.contains($0.key) }
    for item in current where !notifiedDevices.contains(DevicePrompt.key(item)) {
      let key = DevicePrompt.key(item)
      notifiedDevices.insert(key)
      sendNotification(
        .deviceFound, title: LF("发现“%@”", item.title), body: L("要添加吗？添加后，以后插上会自动连接。"),
        identifier: DevicePrompt.notificationID(key), category: DevicePrompt.category,
        userInfo: [DevicePrompt.keyInfo: key])
    }
  }

  // 同意添加：保存为插上自动连接的位置，保存时会连接一次
  func acceptDevicePrompt(_ item: DiscoveredItem) {
    guard var connection = item.connection, mountingPromptDevice == nil else { return }
    let key = DevicePrompt.key(item)
    connection.autoMount = true
    mountingPromptDevice = key
    devicePromptErrors[key] = nil
    system.removeNotifications([DevicePrompt.notificationID(key)])
    operations.start(connectionID: connection.id) { [self] in
      do {
        try await connections.save(connection, password: "")
        // 在挂载前改名，盘名也跟着用设备的型号
        try adoptDeviceModelName(&connection)
        if connection.kind.usesMount { await toggleConnection(connection) }
      } catch is CancellationError {
      } catch {
        devicePromptErrors[key] = HumanError.detail(error, kind: connection.kind)
      }
      if mountingPromptDevice == key { mountingPromptDevice = nil }
    }
  }

  // 设备睡着时发现阶段问不到型号，位置名会自动填成 USB 产品名（如“LAGOON-MTP _SN:…”）。
  // 保存时试连上了、问到了型号，就把这种自动填的名字改成型号；用户自己起的名字不动
  func adoptDeviceModelName(_ connection: inout Connection) throws {
    guard connection.kind == .androidMTP,
      let device = try? MTPUSB.select(params: connection.params, devices: mtpDevices),
      connection.name == device.productName, device.name != device.productName
    else { return }
    try connections.setPresentation(id: connection.id, name: device.name, color: connection.color)
    connection.name = device.name
  }

  // 不添加：这次插着时不再问
  func declineDevicePrompt(_ item: DiscoveredItem) {
    let key = DevicePrompt.key(item)
    declinedDevices.insert(key)
    system.removeNotifications([DevicePrompt.notificationID(key)])
    devicePromptErrors[key] = nil
  }

  // 系统通知上点了按钮
  func respondToDevicePrompt(key: String, accept: Bool) {
    guard let item = promptableDevices.first(where: { DevicePrompt.key($0) == key }) else { return }
    if accept { acceptDevicePrompt(item) } else { declineDevicePrompt(item) }
  }

  // 通知上的“添加”“不用了”两个按钮
  static func registerDevicePromptCategory() {
    let mount = UNNotificationAction(identifier: DevicePrompt.mountAction, title: L("添加"))
    let decline = UNNotificationAction(identifier: DevicePrompt.declineAction, title: L("不用了"))
    let category = UNNotificationCategory(
      identifier: DevicePrompt.category, actions: [mount, decline], intentIdentifiers: [])
    UNUserNotificationCenter.current().setNotificationCategories([category])
  }
}
