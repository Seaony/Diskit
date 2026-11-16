import ChinaWebDrive
import Core
import Foundation
import LanzouDrive
import Quark
import TianyiDrive

extension ConnectionEditorModel {
  var webService: WebLoginService? {
    switch draft.kind {
    case .quark: .quark
    case .ucDrive: .uc
    case .tianyiDrive: .tianyi
    case .mobileCloud: .mobile
    case .thunderDrive: .xunlei
    case .lanzou: draft.params["authMode"] == "share" ? nil : .lanzou
    default: nil
    }
  }

  func completeDemoLogin() {
    draft.params["nickname"] = L("演示账号")
    draft.params["userID"] = "demo-user"
    draft.params["accountReady"] = "true"
    accountSpace = SpaceInfo(total: 256_000_000_000, used: 136_000_000_000)
    if draft.kind == .mobileCloud { draft.params["phone"] = "13800000000" }
    if [.mobileCloud, .thunderDrive, .lanzou].contains(draft.kind) { password = "demo-local-only" }
  }

  func loginWeb(_ service: WebLoginService) async throws {
    stage = L("等待网页登录…")
    try rememberSecretsBeforeLogin()
    if manualLogin && !model.options.isDemo {
      guard
        let credentials = WebLoginCredentialParser.manual(
          password, service: service, phone: draft.params["phone"] ?? "",
          userDomainID: draft.params["userDomainID"] ?? "")
      else { throw ConnectionError.invalidFields }
      try await validateWeb(credentials, service: service)
      return
    }
    guard let webFactory else {
      if model.options.isDemo {
        completeDemoLogin()
        return
      }
      throw ConnectionError.notImplemented
    }
    let authorization = webFactory()
    webLogin = authorization
    defer { webLogin = nil }
    _ = try await authorization.authorize(service: service, options: model.options) {
      [self] credentials in
      try Task.checkCancellation()
      if model.options.isDemo {
        completeDemoLogin()
        return
      }
      try await validateWeb(credentials, service: service)
    }
    if model.options.isDemo { completeDemoLogin() }
  }

  private func validateWeb(_ credentials: WebLoginCredentials, service: WebLoginService)
    async throws
  {
    stage = L("正在验证账号…")
    switch service {
    case .quark, .uc:
      guard let cookie = credentials.cookie else { throw ConnectionError.authentication }
      let account = try await model.quarkSession(for: draft).login(cookie: cookie)
      draft.params["nickname"] = account.nickname
      draft.params["userID"] = account.userID
      accountSpace = SpaceInfo(total: account.total, used: account.used)
    case .tianyi:
      guard let cookie = credentials.cookie else { throw ConnectionError.authentication }
      let account = try await model.tianyiSession(for: draft, personal: true).login(cookie: cookie)
      draft.params["nickname"] = account.displayName.isEmpty ? account.userID : account.displayName
      draft.params["userID"] = account.userID
    case .mobile:
      guard let phone = credentials.phone, let token = credentials.token else {
        throw ConnectionError.authentication
      }
      let provider = MobileCloudProvider(
        session: MobileCloudSession(
          credentials: MobileCloudCredentials(
            phone: phone, token: token, userDomainID: credentials.userDomainID),
          transport: model.makeHTTPTransport()))
      do {
        try await provider.connect()
        accountSpace = try await provider.spaceInfo()
        await provider.disconnect()
      } catch {
        await provider.disconnect()
        throw error
      }
      password = token
      draft.params["phone"] = phone
      draft.params["userDomainID"] = credentials.userDomainID
      draft.params["nickname"] = phone
    case .xunlei:
      guard let token = credentials.token else { throw ConnectionError.authentication }
      let provider = XunleiProvider(
        session: XunleiSession(
          credentials: XunleiCredentials(accessToken: token), transport: model.makeHTTPTransport()))
      do {
        try await provider.connect()
        accountSpace = try await provider.spaceInfo()
        await provider.disconnect()
      } catch {
        await provider.disconnect()
        throw error
      }
      password = token
      draft.params["nickname"] = L("已登录")
    case .lanzou:
      guard let cookie = credentials.cookie else { throw ConnectionError.authentication }
      let provider = LanzouProvider(
        session: LanzouSession(
          configuration: try LanzouConfiguration(authentication: .accountCookie(cookie)),
          transport: model.makeHTTPTransport()))
      do {
        try await provider.connect()
        await provider.disconnect()
      } catch {
        await provider.disconnect()
        throw error
      }
      password = cookie
      draft.params["nickname"] = L("已登录")
    }
    try Task.checkCancellation()
    draft.params["accountReady"] = "true"
  }
}
