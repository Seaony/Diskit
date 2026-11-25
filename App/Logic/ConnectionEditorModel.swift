import ADB
import AppKit
import ChinaWebDrive
import Core
import Foundation
import LanzouDrive
import Observation
import PikPakDrive
import Quark
import S3Drive
import SwiftUI
import TianyiDrive

@MainActor @Observable final class ConnectionEditorModel {
  let model: AppModel
  var didSave = false
  var testSucceeded = false
  var errorNeedsLogin = false
  var lastActionWasLogin = false
  @ObservationIgnored weak var anchorWindow: NSWindow?
  private var loaded = false
  var draft = Connection()
  var password = ""
  var shares: [String] = []
  var error: String? { didSet { errorReport = nil } }
  // 「复制详细信息」复制的完整报告；只有真实错误才有，界面提示文字没有
  @ObservationIgnored var errorReport: String?
  var busy = false
  var chosen = false
  var pairingCode = ""
  var pairingID = ""
  var webLogin: (any WebLoginAuthorizing)?
  let webFactory: (@MainActor () -> any WebLoginAuthorizing)?
  let demoWait: @MainActor () async throws -> Void
  var manualLogin = false
  var accountSpace: SpaceInfo?
  var saving: Task<Void, Never>?
  var pairingTask: Task<Void, Never>?
  var shareTask: Task<Void, Never>?
  // 点过“取消”但可能还没真正结束的任务；关窗口时要等它们结束再撤回钥匙串
  private var cancelledTasks: [Task<Void, Never>] = []
  var selectedKind: ConnectionKind? {
    didSet { if selectedKind != nil { selectedDiscovery = nil } }
  }
  // 第一步选中的“已发现”设备，和 selectedKind 二选一
  var selectedDiscovery: DiscoveredItem? {
    didSet { if selectedDiscovery != nil { selectedKind = nil } }
  }
  var search = ""
  var stage: String?
  var passwordVisible = false
  var guestLogin = false
  var touchedFields: Set<String> = []
  var preparationExpanded = false
  var webdavPreset = "custom"
  var tianyiFamilySpaces: [TianyiFamilySpace] = []
  // 已保存的位置第一次重新登录前的钥匙串内容；没保存就关窗口时写回去
  @ObservationIgnored private var secretsBeforeLogin: [String: Data?]?

  init(
    model: AppModel,
    webFactory: (@MainActor () -> any WebLoginAuthorizing)? = nil,
    demoWait: @escaping @MainActor () async throws -> Void = {
      try await Task.sleep(for: .milliseconds(600))
    }
  ) {
    self.model = model
    self.webFactory = webFactory
    self.demoWait = demoWait
  }
  var isEditing: Bool { model.connections.connections.contains { $0.id == draft.id } }
  var windowTitle: String { EditorWindowTitle.text(name: draft.name, isSaved: isEditing) }
  func synchronizeWindowTitle() {
    guard let window = anchorWindow else { return }
    EditorWindowTitle.synchronize(windowTitle, current: window.title) { window.title = $0 }
  }
  func load() {
    guard !loaded else { return }
    loaded = true
    if let kind = model.options.demoEditorKind,
      let state = model.demoEditorStateOverride ?? model.options.demoEditorState
    {
      applyDemoFixture(kind: kind, state: state)
      return
    }
    draft = model.editing ?? Connection()
    chosen = model.editing != nil
    accountSpace = model.editing.flatMap { EditorAccountSummary.knownSpace(model.connections.states[$0.id]) }
    pairingID = model.pairingSelection ?? ""
    if let connection = model.editing,
      connection.kind == .smb || connection.kind == .webdav || connection.kind == .webdavHTTPS
        || connection.kind.usesStoredRemoteSecret
    {
      do {
        password = try model.connections.savedPassword(connection)
        guestLogin = connection.params["guest"] == "true"
      } catch {
        model.connections.reportOperationError(error)
        recordError(error)
      }
    }
    autoSelectDevice()
    if draft.params["nickname"] != nil
      || (isEditing && draft.kind.usesStoredRemoteSecret && !password.isEmpty)
    {
      draft.params["accountReady"] = "true"
    }
  }
  var missingFields: [String] {
    EditorValidation.requiredFields(
      draft: draft, pairingCode: pairingCode, guest: guestLogin, forceLogin: false
    )
    .filter {
      EditorDraftValue.value(
        $0, draft: draft, pairingID: pairingID, pairingCode: pairingCode, password: password
      ).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }
  var requiresLogin: Bool {
    [.quark, .ucDrive, .pikPak, .tianyiDrive, .mobileCloud, .thunderDrive, .lanzou].contains(
      draft.kind)
      && !(draft.kind == .lanzou && draft.params["authMode"] == "share")
  }
  var hasRequiredLogin: Bool { !requiresLogin || draft.params["accountReady"] == "true" }
  var canSave: Bool {
    !busy && hasRequiredLogin && missingFields.isEmpty
      && EditorValidation.addressIssue(draft) == nil
  }
  var missingFieldsDescription: String? {
    if !hasRequiredLogin { return L("请先登录账号") }
    if let issue = EditorValidation.addressIssue(draft) { return issue }
    guard !missingFields.isEmpty else { return nil }
    return LF("还需要填写：%@", missingFields.map(EditorValidation.label).joined(separator: L("、")))
  }
  func chooseSelected() {
    if let item = selectedDiscovery {
      if let connection = item.connection {
        chooseDiscovered(connection, pairing: item.pairingSelection)
      } else {
        // 还不能直接连接的设备（手机没开 USB 调试）：进对应类型的表单，展开连接指南
        choose(item.kind)
        preparationExpanded = true
      }
      return
    }
    if let kind = selectedKind ?? ConnectionTypeCatalog.matching(search).flatMap(\.kinds).first {
      choose(kind)
    }
  }
  func moveSelection(_ offset: Int) {
    selectedKind = ConnectionTypeCatalog.movedSelection(selectedKind, offset: offset, query: search)
  }
  func showTypes() {
    chosen = false
    selectedKind = draft.kind == .androidWiFi ? .androidUSB : draft.kind
    error = nil
  }
  func fieldError(_ key: String) -> String? {
    guard touchedFields.contains(key) else { return nil }
    if missingFields.contains(key) { return LF("请填写%@", EditorValidation.label(key)) }
    return ["url", "host", "endpoint", "shareURL"].contains(key)
      ? EditorValidation.addressIssue(draft) : nil
  }
  func recordError(_ failure: Error) {
    errorNeedsLogin =
      !NetworkFailure.isTransportError(failure)
      && (failure as? any LoginRequiredFailure)?.requiresLogin == true
    error = HumanError.detail(failure, kind: draft.kind)
    errorReport = HumanError.report(failure, kind: draft.kind)
  }
  func updatePairingCode(_ value: String) {
    pairingCode = PairingDigits.normalized(value)
    if pairingCode.count == 6, draft.params["guid"] == nil, !busy { pairWirelessDevice() }
  }
  func login() {
    guard !busy else { return }
    model.forceLogin = true
    startSave(loginOnly: true)
  }

  func choose(_ kind: ConnectionKind) {
    let previousKind = draft.kind
    let nextKind: ConnectionKind = kind == .webdav ? .webdavHTTPS : kind
    if previousKind != nextKind {
      model.discardUnsavedSecrets(for: draft)
      draft.params.removeAll()
      password = ""
      shares = []
      accountSpace = nil
      manualLogin = false
      pairingCode = ""
      pairingID = ""
      model.forceLogin = false
    }
    draft.kind = nextKind
    let currentName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if currentName.isEmpty || draft.name == previousKind.defaultName {
      draft.name = kind.defaultName
    }
    if kind == .lanzou, draft.params["authMode"] == nil {
      draft.params["authMode"] = "account"
    }
    if kind == .tianyiDrive, draft.params["scope"] == nil {
      draft.params["scope"] = "personal"
    }
    if kind == .androidUSB || kind == .androidWiFi { autoSelectDevice() }
    applyObjectStorageDefaults(for: kind, previousKind: previousKind)
    chosen = true
    error = nil
    touchedFields.removeAll()
  }

  // 从“已发现”进入第二步：带上发现时预填的地址、序列号等
  func chooseDiscovered(_ connection: Connection, pairing: String?) {
    model.discardUnsavedSecrets(for: draft)
    password = ""
    shares = []
    accountSpace = nil
    manualLogin = false
    pairingCode = ""
    model.forceLogin = false
    // 不沿用上一个位置的访客模式
    guestLogin = connection.params["guest"] == "true"
    var discovered = connection
    discovered.id = draft.id
    draft = discovered
    pairingID = pairing ?? ""
    if discovered.kind == .androidUSB { autoSelectDevice() }
    chosen = true
    error = nil
    touchedFields.removeAll()
  }

  func applyObjectStorageDefaults(for kind: ConnectionKind, previousKind: ConnectionKind) {
    guard draft.params["endpoint"] == nil || previousKind != kind,
      let preset = ConnectionTypeCatalog.storagePreset(for: kind)
    else { return }
    draft.params["region"] = preset.defaultRegion
    draft.params["pathStyle"] = preset.pathStyle ? "true" : "false"
    draft.params["endpoint"] = (try? preset.addressing())?.endpoint.absoluteString ?? ""
  }

  var selectedDeviceID: String {
    if let id = draft.params["deviceID"] {
      if draft.kind == .androidUSB {
        return model.usbDevices.first { $0.id == id || $0.serial == id }?.id ?? id
      }
      return id
    }
    let serial = draft.params["serial"] ?? ""
    switch draft.kind {
    case .androidUSB: return model.usbDevices.first { $0.serial == serial }?.id ?? ""
    case .cameraUSB: return model.cameraUSBDevices.first { $0.serial == serial }?.id ?? ""
    default: return ""
    }
  }
  func selectDevice(_ id: String) {
    let rename = draft.name.isEmpty || draft.name == draft.kind.defaultName
    for key in ["deviceID", "usbLocationID", "serial"] { draft.params[key] = nil }
    switch draft.kind {
    case .androidUSB:
      if let device = model.usbDevices.first(where: { $0.id == id }) {
        draft.params.merge(device.connectionParameters(in: model.usbDevices)) { _, new in new }
        if rename { draft.name = device.name }
      }
    case .cameraUSB:
      if let device = model.cameraUSBDevices.first(where: { $0.id == id }) {
        draft.params["deviceID"] = device.id
        if rename { draft.name = device.name }
      }
    default: break
    }
  }
  func autoSelectDevice() {
    guard (draft.params["deviceID"] ?? "").isEmpty, (draft.params["serial"] ?? "").isEmpty else {
      return
    }
    switch draft.kind {
    case .androidUSB: if let device = model.usbDevices.first { selectDevice(device.id) }
    case .cameraUSB: if let device = model.cameraUSBDevices.first { selectDevice(device.id) }
    case .androidWiFi where pairingID.isEmpty:
      // 只发现一台等待配对的手机时直接选上，有好几台让用户自己选
      let devices = model.wirelessDevices.filter { $0.type == .pairing }
      if devices.count == 1 { pairingID = devices[0].id }
    default: break
    }
  }

  // 发现的无线设备变了：能选上就选上；配对码已经填完、刚解析出地址时接着配对
  func wirelessDevicesChanged() {
    guard draft.kind == .androidWiFi, draft.params["guid"] == nil else { return }
    // 选中的配对服务没了（手机上重新打开了配对码页面）就不再留着它
    if !pairingID.isEmpty,
      !model.wirelessDevices.contains(where: { $0.type == .pairing && $0.id == pairingID })
    {
      pairingID = ""
    }
    autoSelectDevice()
    if pairingCode.count == 6, !busy { pairWirelessDevice() }
  }

  func pairWirelessDevice() {
    guard pairingTask == nil,
      let device = model.wirelessDevices.first(where: { $0.id == pairingID }),
      let host = device.host, let port = device.port
    else { return }
    busy = true
    error = nil
    stage = L("正在配对…")
    pairingTask = model.operations.start(connectionID: draft.id, onCancel: cancelWork) { [self] in
      defer {
        busy = false
        stage = nil
        pairingTask = nil
      }
      do {
        let guid =
          model.options.isDemo
          ? "adb-demo-ABC123" : try await ADBPairing.pair(host: host, port: port, code: pairingCode)
        try Task.checkCancellation()
        draft.params["guid"] = guid
        draft.params["name"] = draft.name
        pairingCode = ""
      } catch is CancellationError {
      } catch {
        model.connections.reportOperationError(error)
        self.error =
          (error as? PairingError) == .wrongCode
          ? L("配对码错误，请重新输入。") : HumanError.detail(error, kind: draft.kind)
        errorReport = HumanError.report(error, kind: draft.kind)
        pairingCode = ""
      }
    }
  }

  func listShares() {
    busy = true
    error = nil
    stage = L("正在读取共享列表…")
    shareTask = model.operations.start(connectionID: draft.id, onCancel: cancelWork) { [self] in
      defer {
        busy = false
        stage = nil
        shareTask = nil
      }
      do {
        shares = try await model.connections.listShares(
          host: draft.params["host"] ?? "",
          user: guestLogin ? "" : draft.params["username"] ?? "",
          password: guestLogin ? "" : password)
        try Task.checkCancellation()
        if shares.isEmpty {
          error = L("没有找到可访问的共享，请检查权限或手动填写共享名。")
        } else if let first = shares.first {
          draft.params["share"] = first
        }
      } catch is CancellationError {
      } catch {
        if !Task.isCancelled {
          recordError(error)
        }
      }
    }
  }

  var clearsSharePassword: Bool {
    draft.kind == .lanzou && draft.params["authMode"] == "share" && password.isEmpty
  }

  func save() { startSave(loginOnly: false) }

  func startSave(loginOnly: Bool) {
    guard !busy else { return }
    lastActionWasLogin = loginOnly
    let previous = model.connections.connections.first { $0.id == draft.id }
    busy = true
    error = nil
    if draft.kind == .smb { draft.params["guest"] = guestLogin ? "true" : nil }
    saving = model.operations.start(connectionID: draft.id, onCancel: cancelWork) { [self] in
      defer {
        busy = false
        stage = nil
        saving = nil
        if Task.isCancelled { model.discardUnsavedSessions(for: draft) }
      }
      do {
        if model.options.isDemo {
          if loginOnly {
            if let service = webService {
              try await loginWeb(service)
            } else {
              try await demoWait()
              completeDemoLogin()
            }
            model.forceLogin = false
            return
          }
          stage = L("正在测试连接…")
          try await model.connections.save(
            draft, password: password, clearPassword: clearsSharePassword)
          model.forceLogin = false
          ConnectionPresentationUndo.register(
            previous: previous, current: draft, manager: model.connections, undo: model.undoManager)
          didSave = true
          return
        }
        if draft.kind == .androidWiFi && draft.params["guid"] == nil {
          stage = L("正在配对…")
          guard let device = model.wirelessDevices.first(where: { $0.id == pairingID }),
            let host = device.host, let port = device.port
          else { throw RemoteError.notConnected }
          draft.params["guid"] = try await ADBPairing.pair(
            host: host, port: port, code: pairingCode)
          draft.params["name"] = draft.name
          pairingCode = ""
        }
        try Task.checkCancellation()
        if draft.kind == .quark || draft.kind == .ucDrive {
          let session = model.quarkSession(for: draft)
          let hasCookie = try await session.hasCookie()
          if model.forceLogin || !hasCookie {
            try await loginWeb(draft.kind == .ucDrive ? .uc : .quark)
          } else {
            let account = try await session.account()
            draft.params["nickname"] = account.nickname
            draft.params["userID"] = account.userID
            accountSpace = SpaceInfo(total: account.total, used: account.used)
          }
        }
        if [.mobileCloud, .thunderDrive, .lanzou].contains(draft.kind),
          let service = webService, model.forceLogin || draft.params["accountReady"] != "true"
        {
          try await loginWeb(service)
        }
        if draft.kind == .pikPak {
          stage = model.forceLogin ? L("等待 PikPak 登录…") : L("正在验证账号…")
          let session = model.pikPakSession(for: draft)
          let hasToken = try await session.hasToken()
          let account: PikPakAccount
          if model.forceLogin || !hasToken {
            stage = L("正在登录 PikPak…")
            try rememberSecretsBeforeLogin()
            account = try await session.login(
              username: draft.params["username"] ?? "", password: password)
          } else {
            account = try await session.account()
          }
          draft.params["nickname"] = account.nickname.isEmpty ? account.email : account.nickname
          draft.params["userID"] = account.userID
          accountSpace = SpaceInfo(total: account.total, used: account.used)
          draft.params["accountReady"] = "true"
          if draft.name == draft.kind.defaultName, !account.nickname.isEmpty {
            draft.name = account.nickname
          }
        }
        if draft.kind == .tianyiDrive {
          stage = model.forceLogin ? L("等待天翼云盘登录…") : L("正在验证账号…")
          let authSession = model.tianyiSession(for: draft, personal: true)
          let hasLogin = try await authSession.hasLogin()
          if model.forceLogin || !hasLogin {
            try await loginWeb(.tianyi)
          }
          if draft.params["scope"] == "family" {
            let spaces = try await authSession.familySpaces()
            tianyiFamilySpaces = spaces
            if (draft.params["familyID"] ?? "").isEmpty {
              if spaces.count == 1 {
                draft.params["familyID"] = spaces[0].familyID
              } else if !loginOnly {
                throw TianyiError.invalidFamilyID
              }
            }
          }
          let session = model.tianyiSession(
            for: draft, personal: loginOnly && (draft.params["familyID"] ?? "").isEmpty)
          let account = try await session.account()
          draft.params["nickname"] =
            account.displayName.isEmpty ? account.userID : account.displayName
          draft.params["userID"] = account.userID
          accountSpace = SpaceInfo(total: account.total, used: account.used)
          draft.params["accountReady"] = "true"
          if draft.name == draft.kind.defaultName, !account.displayName.isEmpty {
            draft.name = account.displayName
          }
        }
        if requiresLogin { draft.params["accountReady"] = "true" }
        if loginOnly {
          model.forceLogin = false
          return
        }
        if draft.kind == .smb {
          draft.params["guest"] = guestLogin ? "true" : nil
        }
        try Task.checkCancellation()
        switch draft.kind {
        case .androidUSB, .androidWiFi:
          stage = L("等待手机授权…")
        case .cameraUSB:
          stage = L("等待相机响应…")
        default:
          stage = L("正在测试连接…")
        }
        try await model.connections.save(
          draft, password: guestLogin && draft.kind == .smb ? "" : password,
          clearPassword: clearsSharePassword)
        model.forceLogin = false
        ConnectionPresentationUndo.register(
          previous: previous, current: draft, manager: model.connections, undo: model.undoManager)
        didSave = true
      } catch is CancellationError {
      } catch {
        if !Task.isCancelled {
          model.connections.reportOperationError(error)
          recordError(error)
        }
      }
    }
  }

  // 登录会立刻把新账号写进钥匙串：已保存的位置先记下原来的，没保存就关窗口时写回去
  func rememberSecretsBeforeLogin() throws {
    guard secretsBeforeLogin == nil,
      let saved = model.connections.connections.first(where: { $0.id == draft.id })
    else { return }
    secretsBeforeLogin = try model.sessionSecrets(for: saved)
  }

  // 编辑窗口关闭：没保存时撤回这次登录写进钥匙串的内容。
  // 先等取消的登录真正结束，否则网络返回后迟到的写入会盖掉撤回
  @discardableResult func close() -> Task<Void, Never> {
    let running = [saving, pairingTask, shareTask].compactMap { $0 } + cancelledTasks
    cancelWork()
    cancelledTasks = []
    return Task { [self] in
      for task in running { await task.value }
      guard !didSave else { return }
      if let secretsBeforeLogin { model.restoreSessionSecrets(secretsBeforeLogin, for: draft) }
      secretsBeforeLogin = nil
      model.discardUnsavedSecrets(for: draft)
    }
  }

  func cancelWork() {
    model.discardUnsavedSessions(for: draft)
    cancelledTasks += [saving, pairingTask, shareTask].compactMap { $0 }
    saving?.cancel()
    pairingTask?.cancel()
    shareTask?.cancel()
    webLogin?.cancel()
    model.forceLogin = false
    tianyiFamilySpaces = []
    webLogin = nil
    busy = false
    stage = nil
    saving = nil
    pairingTask = nil
    shareTask = nil
  }

  func resetManualLogin() {
    model.forceLogin = true
    draft.params.removeValue(forKey: "accountReady")
    draft.params.removeValue(forKey: "nickname")
    password = ""
    accountSpace = nil
    draft.params["avatarURL"] = nil
    touchedFields.removeAll()
  }

  func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  func parameter(_ key: String) -> Binding<String> {
    Binding(
      get: { self.draft.params[key] ?? "" },
      set: {
        self.draft.params[key] = $0
      })
  }
}
