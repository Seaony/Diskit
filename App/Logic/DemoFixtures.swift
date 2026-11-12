import Core
import Foundation

struct DemoFixtures {
  let connections: [Connection]
  let states: [UUID: ConnectionState]

  init(scenario: String) {
    let kinds =
      scenario == "types" ? ConnectionKind.allCases : Array(ConnectionKind.allCases.prefix(20))
    let colors = ["blue", "green", "orange", "red", "purple", "pink", "teal", "indigo"]
    if scenario == "empty" || scenario == "discovered" {
      connections = []
      states = [:]
      return
    }
    if scenario == "showcase" {
      (connections, states) = Self.showcase()
      return
    }
    connections = kinds.enumerated().map { index, kind in
      let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!
      let name =
        index == 18
        ? String(repeating: "这是用于检查换行的长名称", count: 4)
        : index == 19
          ? String(repeating: "Long demo location name ", count: 4)
          : "Demo \(kind.rawValue)"
      return Connection(
        id: id, kind: kind, name: name, color: colors[index % colors.count],
        openInFinderAfterMount: false, order: index,
        params: [
          "host": "demo.invalid", "share": "Demo", "username": "demo",
          "serial": "saved-\(index)", "guid": "adb-demo-ABC123",
          "url": "https://demo.invalid/share",
          "path": "/Demo", "endpoint": "https://demo.invalid", "bucket": "demo",
          "accessKey": "demo",
        ])
    }
    let mixedStates: [ConnectionKind: String] = [
      .androidUSB: "authorization", .androidWiFi: "unavailable", .smb: "mounted",
      .ricohGR: "disconnected", .aliyunDrive: "tested", .quark: "login",
      .cameraUSB: "failed", .webdav: "ejecting", .webdavHTTPS: "connecting",
    ]
    states = Dictionary(
      uniqueKeysWithValues: connections.enumerated().map { index, connection in
        let name =
          scenario == "mixed" || scenario == "types"
          ? mixedStates[connection.kind] ?? "disconnected" : scenario
        return (connection.id, Self.state(name, id: connection.id, kind: connection.kind))
      })
  }

  // README 产品图用的一组位置：名字用品牌名或类型名，不新增文案；
  // 只有共享类型显示已挂载，其他类型显示测试通过，和实际能力一致
  private static func showcase() -> ([Connection], [UUID: ConnectionState]) {
    let gb: Int64 = 1_000_000_000
    let items: [(ConnectionKind, String, String, ConnectionState)] = [
      (.smb, "Synology NAS", "blue", .mounted(MountedShare(url: URL(filePath: "/tmp/DiskitDemo/nas"), availableBytes: 2_400 * gb))),
      (.androidUSB, "Pixel 9", "green", .tested(SpaceInfo(total: 256 * gb, used: 142 * gb))),
      (.ricohGR, "GR IV", "orange", .tested(SpaceInfo(total: 128 * gb, used: 37 * gb))),
      (.aliyunDrive, ConnectionKind.aliyunDrive.title, "purple", .tested(SpaceInfo(total: 2_000 * gb, used: 860 * gb))),
      (.webdav, "Nextcloud", "teal", .mounted(MountedShare(url: URL(filePath: "/tmp/DiskitDemo/cloud"), availableBytes: 512 * gb))),
      (.oneDrive, ConnectionKind.oneDrive.title, "blue", .tested(SpaceInfo(total: 1_000 * gb, used: 318 * gb))),
      (.googleDrive, ConnectionKind.googleDrive.title, "green", .disconnected),
      (.cloudflareR2, ConnectionKind.cloudflareR2.title, "orange", .tested(SpaceInfo(total: nil, used: nil))),
      (.dropbox, ConnectionKind.dropbox.title, "blue", .disconnected),
    ]
    var connections: [Connection] = []
    var states: [UUID: ConnectionState] = [:]
    for (index, item) in items.enumerated() {
      let id = UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", index + 1))!
      connections.append(Connection(
        id: id, kind: item.0, name: item.1, color: item.2, openInFinderAfterMount: false, order: index,
        params: ["host": "demo.invalid", "share": "Demo", "username": "demo", "serial": "showcase-\(index)",
                 "url": "https://demo.invalid/dav", "endpoint": "https://demo.invalid", "bucket": "demo", "accessKey": "demo"]))
      states[id] = item.3
    }
    return (connections, states)
  }

  static func state(_ name: String, id: UUID, kind: ConnectionKind) -> ConnectionState {
    switch name {
    case "unavailable": .unavailable
    case "connecting": .connecting
    case "authorization": .awaitingAuthorization
    case "tested": .tested(SpaceInfo(total: 256_000_000_000, used: 136_000_000_000))
    case "mounted":
      .mounted(
        MountedShare(url: URL(filePath: "/tmp/DiskitDemo/\(id)"), availableBytes: 120_000_000_000))
    case "ejecting": .ejecting
    case "failed": .failed(HumanError.remote(.posix(ETIMEDOUT), kind: kind))
    case "login": .needsLogin
    default: .disconnected
    }
  }
}
