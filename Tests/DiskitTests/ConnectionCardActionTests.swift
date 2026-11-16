import Core
import Foundation
import Testing

// 菜单打开时在连接，点“取消”前刚好挂载完成：取消不能变成推出
@Test func cardActionsOnlyRunInTheStateTheyWereShownFor() {
  let mounted = ConnectionState.mounted(MountedShare(url: URL(filePath: "/Volumes/Fixture")))
  #expect(ConnectionCardAction.cancel.allowed(in: .connecting))
  #expect(ConnectionCardAction.cancel.allowed(in: .awaitingAuthorization))
  #expect(!ConnectionCardAction.cancel.allowed(in: mounted))
  #expect(!ConnectionCardAction.cancel.allowed(in: .disconnected))
  #expect(ConnectionCardAction.eject.allowed(in: mounted))
  #expect(!ConnectionCardAction.eject.allowed(in: .connecting))
  #expect(!ConnectionCardAction.eject.allowed(in: .disconnected))
  for state: ConnectionState in [.disconnected, .tested(SpaceInfo(total: 1, used: 0)), .failed("x")] {
    #expect(ConnectionCardAction.connect.allowed(in: state))
  }
  for state: ConnectionState in [mounted, .connecting, .awaitingAuthorization, .ejecting, .unavailable, .needsLogin] {
    #expect(!ConnectionCardAction.connect.allowed(in: state))
  }
}
