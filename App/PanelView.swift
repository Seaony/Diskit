import ADB
import AppKit
import CameraUSB
import Core
import SwiftUI
import UniformTypeIdentifiers

private struct PanelError: Identifiable {
  let id = UUID()
  let title: String
  let message: String
  let report: String
  init(title: String, error: Error) {
    self.title = title
    message = HumanError.detail(error)
    report = HumanError.report(error)
  }
}

private struct ScrollContentHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

struct PanelView: View {
  @Bindable var model: AppModel
  // 从菜单栏下拉打开别的窗口后，把下拉收起；独立面板窗口不收
  var closesOnOpen = false
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var showSettings
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var panelVisible = false
  @State private var stateViewer = UUID()
  @State private var draggedID: UUID?
  @State private var dragSource = PanelDraggingSource()
  @State private var dropTargetID: UUID?
  @State private var endDropTargeted = false
  @AppStorage("panelLayout") private var layout = PanelLayout.grid.rawValue
  @State private var deleteTarget: Connection?
  @State private var actionError: PanelError?
  @State private var selection = PanelSelection()
  @State private var scrollHeight: CGFloat = 240
  @FocusState private var focusedConnectionID: UUID?

  private var discoveryErrors: [(message: String, permissionDenied: Bool)] {
    if let error = model.options.demoDiscoveryError {
      return [(error.message, error.permissionDenied)]
    }
    return [
      model.discovery.error.map { ($0, model.discovery.issue == .permissionDenied) },
      model.wirelessDiscovery.error.map { ($0, model.wirelessDiscovery.issue == .permissionDenied) },
      model.usbDiscovery.issue.map { _ in (L("暂时无法发现 USB 手机，请重新插拔设备"), false) },
      model.cameraUSBDiscovery.issue.map { _ in (L("暂时无法发现相机，请检查 USB 连接"), false) }
    ].compactMap { $0 }
  }

  private var isEmpty: Bool { model.connections.connections.isEmpty }
  private var isGrid: Bool { layout != PanelLayout.list.rawValue }
  // 网格三列，列表一列；上下键按列数跳
  private var columnCount: Int { isGrid ? 3 : 1 }

  var body: some View {
    VStack(spacing: 0) {
      header.gridProbe("header", area: "panel", edge: nil)
      if let failure = model.quitFailure {
        QuitFailureBanner(
          failure: failure,
          onCancel: model.cancelQuitAfterFailure,
          onConfirm: {
            if model.confirmQuitAfterFailure() { NSApplication.shared.terminate(nil) }
          }
        )
        .padding(.horizontal, Space.lg)
        .padding(.bottom, Space.sm)
      }
      if model.fileSystemState == .disabled {
        // 和下面的位置卡片、提示条留出同样的间隔，不要贴在一起
        FileSystemExtensionBanner(state: model.fileSystemState, openSettings: model.openFileSystemSettings)
          .padding(.horizontal, Space.lg)
          .padding(.bottom, Space.sm)
      }
      if PanelCopy.showsEmptyState(savedCount: model.connections.connections.count, hasLoadError: (model.demoSetupError ?? model.connections.loadError) != nil) {
        VStack(spacing: Space.sm) {
          devicePromptBanner
          ForEach(discoveryErrors, id: \.message) { error in
            discoveryBanner(error.message, permissionDenied: error.permissionDenied)
          }
        }.padding(.horizontal, Space.lg)
        emptyState
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: Space.sm) {
              if let error = model.demoSetupError ?? model.connections.loadError {
                errorBanner(error, title: L("无法读取位置列表"))
                  .transition(Motion.appear(reduceMotion: reduceMotion))
              }
              devicePromptBanner
              ForEach(discoveryErrors, id: \.message) { error in
                discoveryBanner(error.message, permissionDenied: error.permissionDenied)
                  .transition(Motion.appear(reduceMotion: reduceMotion))
              }
              if isGrid {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.sm), count: 3), spacing: Space.sm) {
                  cards
                }
              } else {
                VStack(spacing: 0) { cards }
                  .padding(Space.xs)
                  .background(DiskitTheme.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                  .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(DiskitTheme.border, lineWidth: 0.5) }
              }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.md)
            // 增删位置、排序、提示条出现时平滑过渡；减弱动态效果时直接切换，排序只保留插入线
            .animation(Motion.change(reduceMotion: reduceMotion), value: model.connections.connections.map(\.id))
            .animation(Motion.change(reduceMotion: reduceMotion), value: discoveryErrors.map(\.message))
            .animation(Motion.change(reduceMotion: reduceMotion), value: model.devicePrompt?.id)
            // 拖到卡片之外的空白处，放到最后
            .onDrop(of: [.text], delegate: PanelDropDelegate(source: $draggedID, target: $dropTargetID, destination: nil, onTargeted: { endDropTargeted = $0 }, move: move))
            .gridArea("panel-list", inset: Space.lg)
            .background {
              GeometryReader { geometry in
                Color.clear.preference(
                  key: ScrollContentHeightKey.self, value: geometry.size.height)
              }
            }
          }
          .frame(height: min(max(scrollHeight, 60), 468))
          .onChange(of: selection.scrollRequest) { _, request in
            guard let request else { return }
            if reduceMotion { proxy.scrollTo(request.connectionID, anchor: .center) }
            else { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(request.connectionID, anchor: .center) } }
          }
        }
      }
      // 底栏上方一条浅分隔线
      Rectangle().fill(DiskitTheme.border).frame(height: 0.5)
      footer.gridProbe("footer", area: "panel", edge: nil)
    }
    .frame(width: 380)
    .gridArea("panel")
    .gridDiagnostics("panel")
    .demoAppearanceEvidence("panel")
    .background(DiskitTheme.background)
    .buttonStyle(FlatButtonStyle())
    .onDisappear { panelVisible = false }
    .onChange(of: panelVisible) { _, visible in
      model.setFileSystemStateVisible(visible, viewer: stateViewer)
    }
    .onChange(of: draggedID) { _, id in
      if id == nil { dropTargetID = nil; endDropTargeted = false }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: layout)
    .onPreferenceChange(ScrollContentHeightKey.self) { scrollHeight = $0 }
    .background(PanelVisibilityObserver(visible: $panelVisible))
    .background(PanelKeyboardAnchor(handle: handleInitialKey))
    .onAppear {
      model.start()
      // 打开时不选中任何位置，方向键或点击后才有选中
      selection.select(nil, reveal: false)
    }
    .onChange(of: focusedConnectionID) { _, id in
      if let id, id != selection.id { selection.select(id, reveal: false) }
    }
    .onChange(of: model.connections.connections.map(\.id)) { _, ids in selection.keep(in: ids) }
    .onKeyPress(.upArrow) {
      moveSelection(-columnCount)
      return .handled
    }
    .onKeyPress(.downArrow) {
      moveSelection(columnCount)
      return .handled
    }
    .onKeyPress(.leftArrow) {
      guard isGrid else { return .ignored }
      moveSelection(-1)
      return .handled
    }
    .onKeyPress(.rightArrow) {
      guard isGrid else { return .ignored }
      moveSelection(1)
      return .handled
    }
    .onKeyPress(.return) {
      guard let connection = selectedConnection else { return .ignored }
      activate(connection)
      return .handled
    }
    .onKeyPress(.delete) {
      guard let selectedConnection else { return .ignored }; deleteTarget = selectedConnection; return .handled
    }
    .onKeyPress(.escape) {
      if draggedID != nil { draggedID = nil; return .handled }
      NSApplication.shared.keyWindow?.close()
      return .handled
    }
    .focusedSceneValue(\.panelCommands, PanelCommandActions(
      canEdit: selectedConnection != nil, canDelete: selectedConnection != nil,
      edit: { if let selectedConnection { edit(selectedConnection) } },
      delete: { if let selectedConnection { deleteTarget = selectedConnection } }))
    .task(id: panelVisible) {
      guard panelVisible, !model.options.isDemo else { return }
      while !Task.isCancelled {
        await model.connections.refreshMountSpace()
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
      }
    }
    .alert(actionError?.title ?? "", isPresented: Binding(
      get: { actionError != nil }, set: { if !$0 { actionError = nil } }
    ), presenting: actionError) { error in
      Button(L("好"), role: .cancel) { actionError = nil }
      Button(L("复制详细信息")) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(error.report, forType: .string)
      }
    } message: { error in
      Text(error.message)
    }
    .confirmationDialog(
      deleteTitle,
      isPresented: Binding(
        get: { deleteTarget != nil },
        set: { if !$0 { deleteTarget = nil } })
    ) {
      Button(L("删除"), role: .destructive) {
        removeSelectedConnection()
      }
      Button(L("取消"), role: .cancel) { deleteTarget = nil }
    } message: {
      Text(deleteExplanation)
    }
  }

  private var cards: some View {
    ForEach(Array(model.connections.connections.enumerated()), id: \.element.id) { index, connection in
      SavedConnectionRow(
        connection: connection,
        state: model.connections.states[connection.id] ?? .disconnected,
        errorDetail: model.connections.detailedErrors[connection.id],
        capabilities: model.providerCapabilities(for: connection),
        isDemo: model.options.isDemo,
        layout: isGrid ? .grid : .list,
        showsDivider: index > 0,
        dragSource: dragSource,
        selected: selection.id == connection.id,
        rowFocus: $focusedConnectionID,
        canMoveUp: index > 0,
        canMoveDown: index + 1 < model.connections.connections.count,
        onSelect: { selection.select(connection.id, reveal: false) },
        onPrimary: { perform($0, on: connection) },
        onActivate: { activate(connection) },
        onEdit: { edit(connection) },
        onReauthenticate: { edit(connection, reauthenticate: true) },
        onMove: { offset in move(connection, offset: offset) },
        onDelete: { deleteTarget = connection },
        draggedID: $draggedID,
        dropTargetID: $dropTargetID,
        onDrop: { draggedID in move(draggedID, before: connection.id) }
      ).id(connection.id)
        .gridProbe("row-" + connection.id.uuidString, area: "panel-list")
    }
  }

  // 顶栏：标题、卡片/列表切换、添加
  private var header: some View {
    HStack(spacing: Space.sm) {
      // 左边是 logo 和产品名
      HStack(spacing: 10) { // grid: ok logo 与产品名间距 10
        Image("BrandLogo").resizable().interpolation(.high)
          .frame(width: 20, height: 20)
          .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
          .accessibilityHidden(true)
        Text(verbatim: "Diskit").font(.system(size: 14, weight: .semibold))
          .foregroundStyle(DiskitTheme.primaryText)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
      if !isEmpty {
        HStack(spacing: 2) { // grid: ok 分段按钮间隔 2
          layoutButton(.grid, symbol: "square.grid.2x2.fill", label: L("卡片"))
          layoutButton(.list, symbol: "rectangle.grid.1x2.fill", label: L("列表"))
        }
        .padding(2) // grid: ok 分段外框 2
        .background(DiskitTheme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(DiskitTheme.border, lineWidth: 0.5) }
        Button { edit(nil) } label: {
          Image(systemName: "plus").font(.system(size: 13, weight: .bold))
            .foregroundStyle(DiskitTheme.actionText)
            .frame(width: 26, height: 26)
            .background(DiskitTheme.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerStyle(.link)
        .keyboardShortcut("n", modifiers: .command)
        .help(L("添加位置 · ⌘N")).accessibilityLabel(L("添加位置"))
      }
    }
    .padding(.horizontal, Space.lg).padding(.top, Space.md).padding(.bottom, 10) // grid: ok 顶栏下边距 10
  }

  private func layoutButton(_ value: PanelLayout, symbol: String, label: String) -> some View {
    let active = (layout == value.rawValue) || (value == .grid && isGrid)
    return Button { layout = value.rawValue } label: {
      Image(systemName: symbol).font(.system(size: 12))
        .foregroundStyle(active ? DiskitTheme.primaryText : DiskitTheme.tertiaryText)
        .frame(width: 26, height: 22)
        .background(active ? DiskitTheme.segmentSelected : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain).pointerStyle(.link)
    .help(label).accessibilityLabel(label)
    .accessibilityAddTraits(active ? .isSelected : [])
  }

  private var footer: some View {
    HStack(spacing: 2) { // grid: ok 底栏图标间隔 2
      // 左边版本号，补齐图标按钮自带的内边距，和卡片左边对齐
      Text(verbatim: "Diskit " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"))
        .font(.system(size: 11)).monospacedDigit()
        .foregroundStyle(DiskitTheme.tertiaryText)
        .padding(.leading, Space.xs)
      Spacer()
      Button {
        openSettings()
      } label: {
        Image(systemName: "gearshape")
      }
      .keyboardShortcut(",", modifiers: .command)
      .help(L("设置 · ⌘,")).accessibilityLabel(L("打开设置"))
      Button(action: requestQuit) {
        Image(systemName: "power")
      }
      .keyboardShortcut("q", modifiers: .command)
      .help(L("退出 · ⌘Q")).accessibilityLabel(L("退出 Diskit"))
    }.buttonStyle(FlatIconButtonStyle()).padding(.horizontal, Space.md).padding(.top, 6).padding(.bottom, Space.sm) // grid: ok 底栏图标自带内边距，外边距 12 视觉上与卡片对齐
  }

  private var emptyState: some View {
    VStack(spacing: 14) { // grid: ok 设计稿空状态间距
      HStack(alignment: .bottom, spacing: 0) {
        TypeIcon(kind: .androidUSB, color: "green", size: 52)
          .rotationEffect(.degrees(-10)).offset(x: 10, y: 4) // grid: ok 插图错落
        TypeIcon(kind: .quark, color: "blue", size: 60).zIndex(1)
        TypeIcon(kind: .smb, color: "orange", size: 52)
          .rotationEffect(.degrees(10)).offset(x: -10, y: 4) // grid: ok 插图错落
      }
      .padding(.bottom, 10) // grid: ok 插图与标题间距
      Text(L("还没有位置")).font(.system(size: 15, weight: .semibold)).foregroundStyle(DiskitTheme.primaryText)
      // 副标题只是补充说明，比标题弱一档；不用三级文字色，浅色模式下会看不清。
      Text(L("添加后，手机、相机、共享文件夹和网盘\n会像 U 盘一样出现在 Finder 里。"))
        .font(.system(size: 11.5)).foregroundStyle(DiskitTheme.secondaryText.opacity(0.75))
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      Button { edit(nil) } label: { Label(L("添加位置"), systemImage: "plus") }
        .buttonStyle(FlatButtonStyle(prominent: true))
        .keyboardShortcut("n", modifiers: .command)
        .padding(.top, 6) // grid: ok 按钮与说明间距
    }
    .padding(.horizontal, 40).padding(.bottom, Space.xxl)
    .frame(maxWidth: .infinity).frame(height: 340)
  }

  @ViewBuilder private var devicePromptBanner: some View {
    if let item = model.devicePrompt {
      DevicePromptBanner(
        item: item, mounting: model.mountingPromptDevice == DevicePrompt.key(item),
        error: model.devicePromptErrors[DevicePrompt.key(item)],
        mount: { model.acceptDevicePrompt(item) },
        decline: { model.declineDevicePrompt(item) }
      )
      .transition(Motion.appear(reduceMotion: reduceMotion))
    }
  }

  private func discoveryBanner(_ message: String, permissionDenied: Bool) -> some View {
    PanelDiscoveryBanner(message: message, permissionDenied: permissionDenied) {
      if permissionDenied {
        guard !model.options.isDemo else { return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
      } else { edit(nil) }
    }
  }

  private func errorBanner(_ error: String, title: String) -> some View {
    PanelFailureBanner(title: title, message: error)
  }

  private var selectedConnection: Connection? {
    guard let id = selection.id else { return nil }
    return model.connections.connections.first { $0.id == id }
  }

  private func handleInitialKey(_ code: UInt16) -> Bool {
    switch code {
    case 126: moveSelection(-columnCount)
    case 125: moveSelection(columnCount)
    case 123: if isGrid { moveSelection(-1) } else { return false }
    case 124: if isGrid { moveSelection(1) } else { return false }
    case 36, 76:
      guard let selectedConnection else { return false }
      activate(selectedConnection)
    case 51:
      guard let selectedConnection else { return false }
      deleteTarget = selectedConnection
    case 53:
      if draggedID != nil { draggedID = nil }
      else { NSApplication.shared.keyWindow?.close() }
    default: return false
    }
    return true
  }

  private func moveSelection(_ offset: Int) {
    selection.move(offset, in: model.connections.connections.map(\.id))
    if let id = selection.id { focusedConnectionID = id }
  }

  // 点卡片或回车：已挂载就在 Finder 打开，进行中或不可用时不动，登录过期去重新登录，其余连接
  private func activate(_ connection: Connection) {
    switch state(of: connection) {
    case .mounted(let mounted): if !model.options.isDemo { NSWorkspace.shared.open(mounted.url) }
    case .connecting, .awaitingAuthorization, .ejecting, .unavailable: break
    case .needsLogin: edit(connection, reauthenticate: true)
    default: perform(.connect, on: connection)
    }
  }

  private func state(of connection: Connection) -> ConnectionState {
    model.connections.states[connection.id] ?? .disconnected
  }

  private func perform(_ action: ConnectionCardAction, on connection: Connection) {
    guard action.allowed(in: state(of: connection)) else { return }
    switch action {
    case .cancel:
      model.operations.cancel(connectionID: connection.id)
      model.connections.cancelIdleOperation(connection)
    case .eject:
      model.operations.start(connectionID: connection.id) { await model.connections.eject(connection) }
    case .connect:
      model.operations.start(connectionID: connection.id) {
        guard action.allowed(in: state(of: connection)) else { return }
        await model.toggleConnection(connection)
      }
    }
  }

  private func move(_ source: UUID, before target: UUID?) {
    let ids = model.connections.connections.map(\.id)
    guard let index = ids.firstIndex(of: source) else { return }
    let previousNext = ids.dropFirst(index + 1).first
    guard target != source, target != previousNext else { return }
    do {
      try model.connections.reorder(source, before: target)
      model.undoManager.registerUndo(withTarget: model.connections) { _ in
        MainActor.assumeIsolated { move(source, before: previousNext) }
      }
      model.undoManager.setActionName(L("调整位置顺序"))
    } catch {
      actionError = PanelError(title: L("调整位置顺序失败"), error: error)
    }
  }

  private func move(_ connection: Connection, offset: Int) {
    let ids = model.connections.connections.map(\.id)
    guard let index = ids.firstIndex(of: connection.id) else { return }
    let destination = min(max(index + offset, 0), ids.count - 1)
    let target = offset < 0 ? ids[destination] : ids.dropFirst(destination + 1).first
    move(connection.id, before: target)
    selection.select(connection.id, reveal: true)
  }

  private var deleteTitle: String {
    guard let deleteTarget else { return L("删除位置？") }
    return LF("删除“%@”？", deleteTarget.name)
  }

  private var deleteExplanation: String {
    guard let deleteTarget else { return "" }
    if deleteTarget.kind.usesMount {
      return L("会先推出这个位置，再删除保存的登录信息。原文件不受影响。")
    }
    if deleteTarget.kind.isCloud {
      return L("会删除 Diskit 保存的登录信息，网盘里的文件不受影响。")
    }
    return L("会删除 Diskit 保存的位置和登录信息，设备上的文件不受影响。")
  }

  private func removeSelectedConnection() {
    guard let target = deleteTarget else { return }
    deleteTarget = nil
    Task {
      do {
        try await model.connections.remove(target)
      } catch {
        actionError = PanelError(title: LF("删除“%@”失败", target.name), error: error)
      }
    }
  }

  private func edit(_ connection: Connection?, reauthenticate: Bool = false) {
    model.forceLogin = reauthenticate
    model.pairingSelection = nil
    model.editing = connection
    openWindow(id: "connection")
    NSApplication.shared.activate(ignoringOtherApps: true)
    if closesOnOpen { dismiss() }
  }

  private func openSettings() {
    showSettings()
    NSApplication.shared.activate(ignoringOtherApps: true)
    if closesOnOpen { dismiss() }
  }

  private func requestQuit() {
    NSApplication.shared.terminate(nil)
  }

}

extension Connection {
  var tint: Color { DiskitTheme.locationColor(color) }
}
