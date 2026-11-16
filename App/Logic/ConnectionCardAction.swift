import Core

// 卡片菜单里的主操作。菜单按打开时的状态生成，点下去时状态可能已经变了（比如连接刚好完成），
// 这时什么也不做，免得“取消”变成“推出”
enum ConnectionCardAction: Equatable {
  case cancel, eject, connect

  func allowed(in state: ConnectionState) -> Bool {
    switch (self, state) {
    case (.cancel, .connecting), (.cancel, .awaitingAuthorization): true
    case (.eject, .mounted): true
    case (.connect, .disconnected), (.connect, .tested), (.connect, .failed): true
    default: false
    }
  }
}
