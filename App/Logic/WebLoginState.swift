import Core
import Foundation
import Observation

@MainActor @Observable final class WebLoginState {
  let service: WebLoginService
  let options: RuntimeOptions
  var progress = 0.0
  var isLoading = true
  var pageURL: URL?
  var loadError: String?
  var validationError: String?
  var checking = false
  var reloadID = 0
  private var stopped = false
  private var pending: (WebLoginCredentials, Bool)?
  private var previous: WebLoginCredentials?
  private var validation: Task<Void, Never>?
  private let demoWait: @MainActor () async throws -> Void
  private let validate: @MainActor (WebLoginCredentials) async throws -> Void
  private let finish: (Result<WebLoginCredentials, Error>) -> Void

  init(
    service: WebLoginService, options: RuntimeOptions,
    demoWait: @escaping @MainActor () async throws -> Void = {
      try await Task.sleep(for: .seconds(1))
    },
    validate: @escaping @MainActor (WebLoginCredentials) async throws -> Void,
    finish: @escaping (Result<WebLoginCredentials, Error>) -> Void
  ) {
    self.service = service
    self.options = options
    self.demoWait = demoWait
    self.validate = validate
    self.finish = finish
    pageURL = service.loginURL
    if options.isDemo {
      isLoading = options.scenario == "web-loading"
      progress = isLoading ? 0.36 : 1
      if options.scenario == "web-error" { loadError = L("网页暂时无法加载，请重新加载。") }
      if options.scenario == "web-validation-error" { validationError = L("登录信息已失效，请重新登录。") }
    }
  }

  func reload() {
    loadError = nil
    validationError = nil
    previous = nil
    if options.isDemo {
      isLoading = false
      progress = 1
    } else {
      isLoading = true
      progress = 0
      reloadID += 1
    }
  }

  func capture(_ credentials: WebLoginCredentials, manual: Bool = false) {
    guard !stopped, manual || previous != credentials else { return }
    previous = credentials
    pending = (credentials, manual)
    guard !checking else { return }
    checking = true
    validationError = nil
    validation = Task { @MainActor in
      defer {
        checking = false
        validation = nil
      }
      while let (candidate, manual) = pending {
        pending = nil
        do {
          try Task.checkCancellation()
          if options.isDemo { try await demoWait() } else { try await validate(candidate) }
          try Task.checkCancellation()
          finish(.success(candidate))
          return
        } catch {
          guard !Task.isCancelled else { return }
          if manual || !((error as? any LoginRequiredFailure)?.requiresLogin ?? false) {
            validationError = HumanError.detail(error)
          }
        }
      }
    }
  }

  func demonstrateSuccess() {
    guard options.isDemo else { return }
    let credentials: WebLoginCredentials
    switch service {
    case .mobile:
      credentials = WebLoginCredentials(
        phone: "13800000000", token: "demo-local-only", userDomainID: "demo-space")
    case .xunlei: credentials = WebLoginCredentials(token: "demo-local-only")
    default: credentials = WebLoginCredentials(cookie: "demo_local=1")
    }
    capture(credentials, manual: true)
  }

  func demonstrateFailure() {
    guard options.isDemo else { return }
    isLoading = false
    loadError = L("网页暂时无法加载，请重新加载。")
  }

  func retryValidation() {
    guard let previous else { return }
    capture(previous, manual: true)
  }

  func stop() {
    stopped = true
    validation?.cancel()
    validation = nil
    pending = nil
  }
}
