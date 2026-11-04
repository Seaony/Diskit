import Core
import Foundation
import Testing

@MainActor @Test func cancelDemoAuthorizationNeverStartsConnection() async {
  let model = AppModel(options: RuntimeOptions(environment: ["KAYOI_DEMO": "1"]))
  model.start()
  let connection = model.connections.connections.first { $0.kind == .androidUSB }!
  var calls = 0
  model.connections.testRemote = { _ in
    calls += 1
    return SpaceInfo(total: 1, used: 0)
  }
  #expect(model.connections.states[connection.id] == .awaitingAuthorization)
  await model.connections.toggle(connection)
  #expect(calls == 0)
  #expect(model.connections.states[connection.id] == .disconnected)
}
