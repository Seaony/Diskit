import ADB
import Core
import RicohGR
import SwiftUI

struct PanelView: View {
  @Bindable var model: AppModel
  @Environment(\.openWindow) private var openWindow
  @State private var deleteTarget: Connection?
  private var discovered: [DiscoveredSMB] {
    model.discovery.devices.filter { device in
      !model.connections.connections.contains { $0.params["host"] == device.host }
    }
  }
  private var discoveredUSB: [ADBDevice] {
    model.usbDiscovery.devices.filter { device in
      !model.connections.connections.contains {
        $0.kind == .androidUSB && $0.params["serial"] == device.serial
      }
    }
  }
  private var discoveredWiFi: [WirelessDevice] {
    model.wirelessDiscovery.devices.filter { device in
      !model.connections.connections.contains { $0.params["guid"] == device.name }
    }
  }
  private var discoveredCameras: [RicohDevice] {
    model.ricohDiscovery.devices.filter { device in
      !model.connections.connections.contains {
        $0.kind == .ricohGR && $0.params["serial"] == device.serial
      }
    }
  }
  private var contentHeight: CGFloat {
    min(
      422,
      CGFloat(
        model.connections.connections.count + discovered.count + discoveredUSB.count
          + discoveredWiFi.count + discoveredCameras.count)
        * 60
        + (model.connections.connections.isEmpty ? 210 : 100) + (discovered.isEmpty ? 0 : 32))
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Kayoi").font(.title.bold())
        Spacer()
        Text(String(format: L("%d 个已挂载"), model.connections.mountedCount)).font(.caption)
          .padding(.horizontal, 8).padding(.vertical, 4).background(.quaternary, in: Capsule())
      }.padding(16)
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          if let error = model.connections.loadError {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
          }
          if let error = model.discovery.error {
            Text(error).font(.caption).foregroundStyle(.secondary)
          }
          if let error = model.wirelessDiscovery.error {
            Text(error).font(.caption).foregroundStyle(.secondary)
          }
          if !discovered.isEmpty || !discoveredUSB.isEmpty || !discoveredWiFi.isEmpty
            || !discoveredCameras.isEmpty
          {
            Text("已发现").font(.caption).foregroundStyle(.secondary)
          }
          ForEach(discoveredCameras) { device in
            HStack {
              Image(systemName: "camera").frame(width: 28, height: 28)
              Text(device.name).lineLimit(1)
              Spacer()
              Button("添加") {
                edit(
                  Connection(kind: .ricohGR, name: device.name, params: ["serial": device.serial]))
              }.controlSize(.small)
            }.frame(height: 52).padding(.horizontal, 10).background(
              .background, in: RoundedRectangle(cornerRadius: 10))
          }
          ForEach(discoveredWiFi) { device in
            HStack {
              Image(systemName: "wifi").frame(width: 28, height: 28)
              VStack(alignment: .leading) {
                Text(device.name + L("（Wi-Fi）")).lineLimit(1)
                Text(device.type == .pairing ? L("配对服务") : L("无线调试")).font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Button("添加") {
                let connection = Connection(
                  kind: .androidWiFi, name: device.name,
                  params: device.type == .connect ? ["guid": device.name] : [:])
                edit(connection)
                model.pairingSelection = device.type == .pairing ? device.id : nil
              }.controlSize(.small)
            }.frame(height: 52).padding(.horizontal, 10).background(
              .background, in: RoundedRectangle(cornerRadius: 10))
          }
          if !discoveredUSB.isEmpty {
            ForEach(discoveredUSB) { device in
              HStack {
                Image(systemName: "smartphone").frame(width: 28, height: 28)
                VStack(alignment: .leading) {
                  Text(device.name)
                  Text(device.serial).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("添加") {
                  edit(
                    Connection(
                      kind: .androidUSB, name: device.name, params: ["serial": device.serial]))
                }.controlSize(.small)
              }.frame(height: 52).padding(.horizontal, 10).background(
                .background, in: RoundedRectangle(cornerRadius: 10))
            }
          }
          if !discovered.isEmpty {
            ForEach(discovered) { device in
              HStack(spacing: 10) {
                typeIcon(color: .blue)
                VStack(alignment: .leading) {
                  Text(device.name).lineLimit(1)
                  Text(device.host ?? L("正在解析地址…")).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button("添加") {
                  edit(Connection(name: device.name, params: ["host": device.host ?? ""]))
                }
                .disabled(device.host == nil).controlSize(.small)
              }.frame(height: 52).padding(.horizontal, 10).background(
                .background, in: RoundedRectangle(cornerRadius: 10))
            }
          }
          if model.connections.connections.isEmpty {
            VStack(spacing: 10) {
              Image(systemName: "externaldrive.badge.plus").font(.system(size: 36)).foregroundStyle(
                .secondary)
              Text("还没有保存的位置").font(.headline)
              Text("添加共享，让文件出现在 Finder 中").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 24)
          } else {
            Text("我的位置").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            ForEach(model.connections.connections) { connection in
              row(connection)
                .draggable(connection.id.uuidString)
                .dropDestination(for: String.self) { ids, _ in
                  guard let value = ids.first, let id = UUID(uuidString: value) else {
                    return false
                  }
                  do {
                    try model.connections.reorder(id, before: connection.id)
                    return true
                  } catch {
                    model.alert = error.localizedDescription
                    return false
                  }
                }
            }
          }
          Button {
            edit(nil)
          } label: {
            Label("添加位置", systemImage: "plus")
          }.frame(maxWidth: .infinity).padding(.vertical, 6)
        }.padding(.horizontal, 16).padding(.bottom, 8)
      }.frame(height: contentHeight)
      Divider()
      HStack {
        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "").font(
          .caption
        ).foregroundStyle(.secondary)
        Spacer()
        Button {
          model.showHelp()
        } label: {
          Image(systemName: "questionmark.circle")
        }.help("帮助").accessibilityLabel("帮助")
        Button {
          openWindow(id: "settings")
          NSApplication.shared.activate(ignoringOtherApps: true)
        } label: {
          Image(systemName: "gearshape")
        }.help("设置").accessibilityLabel("设置")
        Button {
          NSApplication.shared.terminate(nil)
        } label: {
          Image(systemName: "power")
        }.help("退出").accessibilityLabel("退出")
      }.buttonStyle(.borderless).padding(12)
    }.frame(width: 380)
      .task {
        model.start()
        while !Task.isCancelled {
          model.connections.refreshMounts()
          do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
      }
      .alert(
        "操作失败",
        isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })
      ) {
        Button("好") { model.alert = nil }
      } message: {
        Text(model.alert ?? "")
      }
      .confirmationDialog(
        "删除连接？已挂载的共享会先推出。",
        isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
      ) {
        Button("删除连接", role: .destructive) {
          guard let target = deleteTarget else { return }
          deleteTarget = nil
          Task {
            do { try await model.connections.remove(target) } catch {
              model.alert = error.localizedDescription
            }
          }
        }
      }
  }
  private func edit(_ connection: Connection?) {
    model.pairingSelection = nil
    model.editing = connection
    openWindow(id: "connection")
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
  private func typeIcon(color: Color) -> some View {
    Image(systemName: "desktopcomputer").foregroundStyle(.white).frame(width: 28, height: 28)
      .background(color, in: RoundedRectangle(cornerRadius: 7))
  }
  private func row(_ connection: Connection) -> some View {
    let state = model.connections.states[connection.id] ?? .disconnected
    return HStack(spacing: 10) {
      Image(
        systemName: (connection.kind == .androidUSB || connection.kind == .androidWiFi)
          ? "smartphone" : (connection.kind == .ricohGR ? "camera" : "desktopcomputer")
      )
      .foregroundStyle(.white).frame(width: 28, height: 28).background(
        connection.tint, in: RoundedRectangle(cornerRadius: 7))
      VStack(alignment: .leading, spacing: 3) {
        Text(connection.name).font(.body.weight(.medium)).lineLimit(1)
        Text(subtitle(state)).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(
          subtitle(state))
      }
      Spacer(minLength: 0)
      Button(connection.kind == .smb ? buttonTitle(state) : L("测试连接")) {
        Task { await model.connections.toggle(connection) }
      }
      .buttonStyle(.bordered).controlSize(.small).disabled(state == .connecting)
    }.frame(height: 52).padding(.horizontal, 10).background(
      .background, in: RoundedRectangle(cornerRadius: 10)
    )
    .contextMenu {
      if case .mounted(let mounted) = state {
        Button("在 Finder 中打开") { NSWorkspace.shared.open(mounted.url) }
      }
      Button("编辑") { edit(connection) }
      Button("删除连接", role: .destructive) { deleteTarget = connection }
    }
  }
  private func subtitle(_ state: ConnectionState) -> String {
    switch state {
    case .disconnected: L("未连接")
    case .connecting: L("连接中…")
    case .failed(let error): error
    case .tested(let space):
      String(
        format: L("连接成功 · 可用 %@"),
        ByteCountFormatter.string(fromByteCount: space.available, countStyle: .file))
    case .mounted(let mount):
      String(
        format: L("已挂载 · 可用 %@"),
        ByteCountFormatter.string(fromByteCount: mount.availableBytes, countStyle: .file))
    }
  }
  private func buttonTitle(_ state: ConnectionState) -> String {
    switch state {
    case .tested: L("测试连接")
    case .mounted: L("推出")
    case .failed: L("重试")
    case .connecting: L("连接中…")
    case .disconnected: L("挂载")
    }
  }
}

extension Connection {
  var tint: Color {
    switch color {
    case "green": .green
    case "orange": .orange
    case "red": .red
    default: .blue
    }
  }
}
