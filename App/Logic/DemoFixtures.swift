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

  static func state(_ name: String, id: UUID, kind: ConnectionKind) -> ConnectionState {
    switch name {
    case "unavailable": .unavailable
    case "connecting": .connecting
    case "authorization": .awaitingAuthorization
    case "tested": .tested(SpaceInfo(total: 256_000_000_000, used: 136_000_000_000))
    case "mounted":
      .mounted(
        MountedShare(url: URL(filePath: "/tmp/KayoiDemo/\(id)"), availableBytes: 120_000_000_000))
    case "ejecting": .ejecting
    case "failed": .failed(HumanError.remote(.posix(ETIMEDOUT), kind: kind))
    case "login": .needsLogin
    default: .disconnected
    }
  }
}
