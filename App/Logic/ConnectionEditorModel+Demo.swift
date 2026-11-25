import Core

extension ConnectionEditorModel {
  func applyRequestedDemoState() async {
    guard model.options.isDemo, let state = model.demoEditorStateOverride else { return }
    let kind = draft.kind
    let pending = [saving, pairingTask, shareTask].compactMap { $0 }
    cancelWork()
    for task in pending { await task.value }
    guard !Task.isCancelled else { return }
    applyDemoFixture(kind: kind, state: state)
  }

  func applyDemoFixture(kind: ConnectionKind, state: DemoEditorState) {
    guard model.options.isDemo else { return }
    didSave = false
    manualLogin = false
    passwordVisible = false
    guestLogin = false
    lastActionWasLogin = false
    webdavPreset = "custom"
    tianyiFamilySpaces = []
    draft = Connection()
    draft.kind = kind
    draft.name = kind.defaultName
    chosen = true
    error = nil
    errorNeedsLogin = false
    password = ""
    accountSpace = nil
    shares = []
    stage = nil
    pairingID = ""
    pairingCode = ""
    touchedFields.removeAll()
    busy = false
    testSucceeded = false
    if state == .blank {
      if kind == .lanzou { draft.params["authMode"] = "account" }
      if kind == .tianyiDrive { draft.params["scope"] = "personal" }
      return
    }
    draft.params = [
      "host": "demo.invalid", "share": "Photos", "username": "demo@example.invalid",
      "url": kind == .webdav ? "http://demo.invalid/dav/" : "https://demo.invalid/dav/",
      "path": "/Photos", "endpoint": "https://objects.demo.invalid", "bucket": "photos",
      "accessKey": "demo-access", "region": "us-east-1", "pathStyle": "false",
      "serial": "demo-usb",
      "deviceID": kind == .cameraUSB ? "demo-camera" : "demo-usb",
      "guid": "adb-demo-ABC123", "authMode": "account", "scope": "personal",
      "shareURL": "https://demo.invalid/share", "familyID": "demo-family",
    ]
    password = "demo-local-only"
    if requiresLogin { completeDemoLogin() }
    if kind == .androidWiFi && state == .filled {
      draft.params["guid"] = nil
      pairingID = model.wirelessDevices.first?.id ?? ""
      pairingCode = "123"
    }
    switch state {
    case .blank, .filled: break
    case .error:
      error = HumanError.timeout(kind: kind)
    case .testing:
      busy = true
      stage = L("正在测试连接…")
    case .success:
      testSucceeded = true
    }
  }
}
