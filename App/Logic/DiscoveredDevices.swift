import ADB
import CameraUSB
import Core
import Foundation
import RicohGR

struct DiscoveredItem: Identifiable {
  let id: String
  let kind: ConnectionKind
  let title: String
  let subtitle: String
  let connection: Connection?
  let pairingSelection: String?
}

struct MergedWirelessDevice {
  let key: String
  let pairing: WirelessDevice?
  let connect: WirelessDevice?
  var serviceName: String { connect?.name ?? pairing?.name ?? key }
}

extension AppModel {
  private var mergedWirelessDevices: [MergedWirelessDevice] {
    let grouped = Dictionary(grouping: wirelessDevices) { device in
      WirelessSelection.serial(fromGUID: device.name) ?? device.name
    }
    return grouped.map { key, devices in
      MergedWirelessDevice(
        key: key,
        pairing: devices.first { $0.type == .pairing },
        connect: devices.first { $0.type == .connect })
    }.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
  }

  // 已发现但还没保存的设备，按类型和名称排序
  var discoveredItems: [DiscoveredItem] {
    var items: [DiscoveredItem] = []

    for camera in ricohDevices
    where !PanelDiscoveryIdentity.isSavedDevice(connections.connections, kinds: [.ricohGR, .cameraUSB], id: camera.id, serial: camera.serial, serialIsUnique: ricohDevices.filter { $0.serial == camera.serial }.count == 1) {
      items.append(
        DiscoveredItem(
          id: "camera:" + camera.id, kind: .ricohGR, title: camera.name,
          subtitle: L("USB 相机"),
          connection: Connection(
            kind: .ricohGR, name: camera.name, params: ["deviceID": camera.id, "serial": camera.serial]),
          pairingSelection: nil))
    }

    for camera in cameraUSBDevices
    where !ricohDevices.contains(where: { PanelDiscoveryIdentity.sameCamera(id: camera.id, serial: camera.serial, otherID: $0.id, otherSerial: $0.serial) }) && !PanelDiscoveryIdentity.isSavedDevice(connections.connections, kinds: [.ricohGR, .cameraUSB], id: camera.id, serial: camera.serial, serialIsUnique: cameraUSBDevices.filter { $0.serial == camera.serial }.count == 1) {
      items.append(
        DiscoveredItem(
          id: "camera-usb:" + camera.id, kind: .cameraUSB, title: camera.name,
          subtitle: L("USB 相机"),
          connection: Connection(
            kind: .cameraUSB, name: camera.name, params: ["deviceID": camera.id, "serial": camera.serial]),
          pairingSelection: nil))
    }

    for device in usbDevices
    where !PanelDiscoveryIdentity.isSavedDevice(connections.connections, kinds: [.androidUSB], id: device.id, serial: device.serial, serialIsUnique: usbDevices.filter { $0.serial == device.serial }.count == 1) {
      items.append(
        DiscoveredItem(
          id: "usb:" + device.id, kind: .androidUSB, title: device.name,
          subtitle: L("USB 数据线"),
          connection: Connection(
            kind: .androidUSB, name: device.name, params: device.connectionParameters(in: usbDevices)),
          pairingSelection: nil))
    }

    // 插着但没开 USB 调试的安卓手机：先列出来，点进去看连接指南打开 USB 调试
    for phone in phonesWithoutDebugging
    where !usbDevices.contains(where: { !phone.serial.isEmpty && $0.serial == phone.serial }) {
      items.append(
        DiscoveredItem(
          id: "phone-setup:" + phone.id, kind: .androidUSB, title: phone.name,
          subtitle: L("需要打开 USB 调试"), connection: nil, pairingSelection: nil))
    }

    for device in mergedWirelessDevices where !isSaved(device) {
      let connect = device.connect
      let pairing = device.pairing
      let title =
        WirelessSelection.serial(fromGUID: device.serviceName).map {
          LF("Android 手机 · %@", $0)
        }
        ?? device.serviceName
      let modes =
        [pairing == nil ? nil : L("可配对"), connect == nil ? nil : L("可连接")]
        .compactMap { $0 }.joined(separator: L(" · "))
      let connection = Connection(
        kind: .androidWiFi, name: title,
        params: connect.map { ["guid": $0.name] } ?? [:])
      items.append(
        DiscoveredItem(
          id: "wifi:" + device.key, kind: .androidWiFi, title: title, subtitle: L("Wi‑Fi 无线调试") + " · " + modes,
          connection: connection, pairingSelection: pairing?.id))
    }

    for device in smbDevices
    where !PanelDiscoveryIdentity.isSavedSMB(connections.connections, id: device.id, host: device.host) {
      items.append(
        DiscoveredItem(
          id: "smb:" + device.id, kind: .smb, title: device.name,
          subtitle: L("局域网") + " · " + (device.host ?? device.name),
          connection: Connection(kind: .smb, name: device.name, params: ["bonjourID": device.id].merging(device.host.map { ["host": $0] } ?? [:]) { _, new in new }), pairingSelection: nil))
    }

    return items.sorted { lhs, rhs in
      if lhs.kind == rhs.kind {
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
      }
      return lhs.kind.sortOrder < rhs.kind.sortOrder
    }
  }

  private func isSaved(_ device: MergedWirelessDevice) -> Bool {
    connections.connections.contains { connection in
      guard connection.kind == .androidWiFi, let guid = connection.params["guid"] else {
        return false
      }
      if guid == device.serviceName { return true }
      let services = [device.pairing, device.connect].compactMap { $0 }
      return services.contains { WirelessSelection.matches(guid: guid, service: $0) }
        || WirelessSelection.serial(fromGUID: guid) == device.key
    }
  }
}

extension ConnectionKind {
  // 已发现设备按类型排序：手机、局域网、相机、网盘、对象存储
  var sortOrder: Int {
    switch self {
    case .androidUSB, .androidWiFi: 0
    case .smb, .webdav, .webdavHTTPS, .nfs: 1
    case .ricohGR, .cameraUSB: 2
    case .aliyunDrive, .quark, .baiduDrive, .drive115, .drive123, .oneDrive, .googleDrive,
      .dropbox, .ucDrive, .tianyiDrive, .mobileCloud, .thunderDrive, .pikPak, .lanzou:
      3
    case .s3, .cloudflareR2, .aliyunOSS, .tencentCOS, .qiniuKodo, .minIO, .backblazeB2: 4
    }
  }
}
